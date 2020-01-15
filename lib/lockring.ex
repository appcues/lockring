defmodule Lockring do
  @moduledoc ~S"""
  Lockring is a mutex and semaphore library for BEAM languages.

  Use it when you need exclusive or moderated access to a single resource or
  one of a pool of resources.

  These resources can be static data or GenServers. In the latter case,
  GenServer crashes are handled automatically, replacing the crashed server
  and releasing its lock.

  Lockring uses Erlang's `:persistent_term`, `:atomics`, and ETS tables
  to coordinate locking, providing high scalability without the bottleneck
  and message-passing overhead of a GenServer-based system.
  """

  use Lockring.Debug
  import Lockring.Config, only: [config: 2]

  @type name :: any
  @type index :: non_neg_integer
  @type lock_ref :: {name, index, reference}
  @type resource :: any

  @type general_opt ::
          {:spin_delay, nil | non_neg_integer}

  @type new_opt ::
          {:size, pos_integer}
          | {:semaphore, pos_integer}
          | {:resource, resource_spec}

  @type resource_spec :: :none | {module, any} | (name, index -> any)

  @type timeout_opt ::
          {:timeout, timeout}
          | {:wait_timeout, timeout}
          | {:fun_timeout, timeout}

  @doc false
  @spec init(Keyword.t()) :: :ok
  def init(_opts) do
    pool_count = :atomics.new(1, [])
    :persistent_term.put(Lockring.PoolCount, pool_count)

    new_lock = :atomics.new(1, [])
    :persistent_term.put(Lockring.NewLock, new_lock)

    :ok
  end

  @doc ~S"""
  Creates a new Lockring pool.

  Options:

  * `:size` - The number of resources in this pool. Default 1.

  * `:semaphore` - The number of simultaneous locks to permit on a single
    resource. Default 1 (i.e., a mutex).

  * `:resource` - Function or `{module, opts}` tuple for generating
    resources.

    If a function is supplied, it must be of arity 2. The return
    value of `fun.(name, index)` will be used as the resource.

    If `module` and `opts` are supplied, they will be used as inputs to
    `GenServer.start_link/2`, adding `:name` and `:index` to the given `opts`.
    The resulting pid will be used as the resource.  If this process crashes,
    a new one will take its place in the pool automatically.

    If no `resource` is supplied, the atom `:none` is used as the resource.
    This is useful for creating locks that are not attached to a given
    resource.  This is the default behavior.
  """
  @spec new(name, [new_opt | general_opt]) :: :ok
  def new(name, opts \\ []) do
    new_lock = :persistent_term.get(Lockring.NewLock)

    case :atomics.add_get(new_lock, 1, 1) do
      1 ->
        try do
          if !:persistent_term.get({Lockring.Table, name}, nil) do
            debug("creating #{inspect(name)}")
            :ok = GenServer.call(Lockring.Maker, {:new, name, opts})
          end
        after
          :atomics.sub(new_lock, 1, 1)
        end

      n ->
        if n > 1, do: :atomics.sub(new_lock, 1, 1)
        spin(opts)
        new(name, opts)
    end

    :ok
  end

  @doc ~S"""
  Attempts one time to acquire a lock on a resource in a pool.

  If the pool did not exist, it will be created, respecting the options
  passed in `opts`.

  Returns `{:ok, lock_ref, resource}` if a lock was acquired,
  `:fail` if the resource is already locked, or `{:error, reason}` if
  something went wrong.

  If the lock was acquired, the user must be sure to release it with
  `Lockring.release(lock_ref)` when finished with it.

  To keep trying for a lock, see `wait_for_lock/2`.

  To lock a resource and execute a function on it, see `with_lock/3`.
  """
  @spec lock(name, [new_opt | general_opt]) ::
          {:ok, lock_ref, resource} | :fail | {:error, String.t()}
  def lock(name, opts \\ []) do
    case lock_with_index(name, opts) do
      {:fail, _index} -> :fail
      other -> other
    end
  end

  defp lock_with_index(name, opts) do
    case locks(name) do
      nil ->
        new(name, opts)
        spin()
        lock(name, opts)

      locks ->
        index = next_index(name)

        case :atomics.sub_get(locks, index, 1) do
          n when n >= 0 ->
            resource = get_resource(name, index, opts)
            resource_ref = get_resource_ref(name, index, opts)
            lock_ref = {name, index, resource_ref}
            debug("Locked #{inspect(lock_ref)}")
            {:ok, lock_ref, resource}

          _ ->
            :atomics.add(locks, index, 1)
            {:fail, index}
        end
    end
  end

  @doc ~S"""
  Releases a lock.
  """
  @spec release(lock_ref) :: :ok
  def release(lock_ref) do
    {name, index, resource_ref} = lock_ref

    case get_resource_ref(name, index) do
      ^resource_ref ->
        if wait_queue_flag(name, index) > 0 do
          resource = get_resource(name, index)
          wait_queue(name, index) |> Lockring.WaitQueue.next(lock_ref, resource)
          debug("Passed #{inspect(lock_ref)} to waiting process")
        else
          :atomics.add(locks(name), index, 1)
          debug("Released #{inspect(lock_ref)}")
        end

      _ ->
        debug("Ignoring release on stale ref: #{inspect(lock_ref)}")
    end

    :ok
  end

  @doc ~S"""
  Attempts to acquire a lock on a resource in a pool until the given timeout
  is reached. Passing `:infinity` as the timeout will wait forever for
  a lock.

  Returns `{:ok, lock_ref, resource}` if a lock was acquired,
  `:fail` if the resource is already locked, or `{:error, reason}` if
  something went wrong.
  """
  @spec wait_for_lock(name, timeout, [new_opt | general_opt]) ::
          {:ok, lock_ref, resource} | :fail | {:error, String.t()}
  def wait_for_lock(name, timeout \\ :infinity, opts \\ []) do
    case lock_with_index(name, opts) do
      {:ok, _lock_ref, _resource} = success ->
        success

      {:fail, index} ->
        timeout_at =
          case timeout do
            :infinity -> :infinity
            t -> now() + t
          end

        case wait_queue(name, index) |> Lockring.WaitQueue.await(timeout_at) do
          :fail ->
            :fail

          :ok ->
            receive do
              {Lockring.GoAhead, lock_ref, resource} ->
                {:ok, lock_ref, resource}
            after
              timeout -> :fail
            end
        end
    end
  end

  @doc ~S"""
  Attempts to acquire a lock on a resource, If successful, executes
  `fun.(resource)` and passes its return value in an `{:ok, value}` tuple.

  During lock wait and the execution of `fun`, the *lowest* applicable
  timeout value will be used.

  Options:

  * `:timeout` - Maximum number of milliseconds before `with_lock` returns.
    This includes both wait and execution time. Default 5000.
    Set to `:infinity` to wait forever, or set to `nil` to observe only
    `:wait_timeout` and `:fun_timeout`.

  * `:wait_timeout` - Maximum number of milliseconds to wait when acquiring
    a lock. Default `:infinity`.

  * `:fun_timeout` - Maximum number of milliseconds to wait when executing
    `fun.(resource)`. Default `:infinity`.
    execution to finish.
  """
  @spec with_lock(name, (resource -> any), [new_opt | timeout_opt | general_opt]) ::
          {:ok, any} | {:error, String.t()}
  def with_lock(name, fun, opts \\ []) do
    timeout = :timeout |> config(opts)
    wait_timeout = :wait_timeout |> config(opts)
    fun_timeout = :fun_timeout |> config(opts)

    shortest_wait_timeout =
      case {timeout, wait_timeout} do
        {nil, _} -> wait_timeout
        {:infinity, _} -> wait_timeout
        {_, :infinity} -> timeout
        {_, _} -> min(timeout, wait_timeout)
      end

    non_neg_wait_timeout =
      if shortest_wait_timeout == :infinity do
        :infinity
      else
        max(0, shortest_wait_timeout)
      end

    start_time = now()

    case wait_for_lock(name, non_neg_wait_timeout, opts) do
      :fail ->
        {:error, "wait_timeout reached"}

      {:ok, lock_ref, resource} ->
        try do
          task =
            Task.async(fn ->
              try do
                fun.(resource)
              rescue
                e -> {:task_error, e}
              end
            end)

          elapsed = now() - start_time

          shortest_fun_timeout =
            case {timeout, fun_timeout} do
              {nil, _} -> fun_timeout
              {:infinity, _} -> fun_timeout
              {_, :infinity} -> timeout - elapsed
              {_, _} -> min(timeout - elapsed, fun_timeout)
            end

          non_neg_fun_timeout =
            if shortest_fun_timeout == :infinity do
              :infinity
            else
              max(0, shortest_fun_timeout)
            end

          case Task.yield(task, max(0, non_neg_fun_timeout)) do
            {:ok, {:task_error, e}} ->
              {:error, Exception.message(e)}

            {:ok, return_value} ->
              {:ok, return_value}

            nil ->
              Task.shutdown(task)
              {:error, "fun_timeout reached"}
          end
        after
          release(lock_ref)
        end

      error ->
        error
    end
  end

  #### Public API ends here

  @doc false
  @spec now() :: integer
  def now do
    :erlang.monotonic_time(:millisecond)
  end

  @doc false
  @spec get_resource(name, index, [general_opt]) :: :ok
  def get_resource(name, index, opts \\ []) do
    table = :persistent_term.get({Lockring.Table, name})
    get_resource_from_table(table, index, opts)
  end

  defp get_resource_from_table(table, index, opts) do
    case :ets.lookup(table, {:resource, index}) do
      [{_, r}] ->
        r

      [] ->
        spin(opts)
        get_resource_from_table(table, index, opts)
    end
  end

  @doc false
  @spec put_resource(name, index, resource) :: :ok
  def put_resource(name, index, resource) do
    table = :persistent_term.get({Lockring.Table, name})
    put_resource_in_table(table, index, resource)
  end

  defp put_resource_in_table(table, index, resource) do
    resource_ref = make_ref()
    true = :ets.insert(table, {{:resource, index}, resource})
    true = :ets.insert(table, {{:resource_ref, index}, resource_ref})
    :ok
  end

  defp get_resource_ref(name, index, opts \\ []) do
    table = :persistent_term.get({Lockring.Table, name})
    get_resource_ref_from_table(table, index, opts)
  end

  defp get_resource_ref_from_table(table, index, opts) do
    case :ets.lookup(table, {:resource_ref, index}) do
      [{_, ref}] ->
        ref

      [] ->
        spin(opts)
        get_resource_from_table(table, index, opts)
    end
  end

  defp next_index(name) do
    case :persistent_term.get({Lockring.Index, name}, nil) do
      nil ->
        spin()
        next_index(name)

      index ->
        i = :atomics.add_get(index, 1, 1)
        rem(i, size(name)) + 1
    end
  end

  defp wait_queue(name, index) do
    queues = :persistent_term.get({Lockring.WaitQueues, name}, nil)
    queues[index]
  end

  defp wait_queue_flag(name, index) do
    flags = :persistent_term.get({Lockring.WaitQueueFlags, name}, nil)
    :atomics.get(flags, index)
  end

  defp spin(opts \\ []) do
    case config(:spin_delay, opts) do
      nil ->
        :ok

      spin_delay ->
        delay = round((1 + :random.uniform()) * spin_delay)
        Process.sleep(delay)
    end
  end

  defp size(name) do
    :persistent_term.get({Lockring.Size, name})
  end

  @doc false
  @spec locks(name) :: :atomics.atomics_ref() | nil
  def locks(name) do
    :persistent_term.get({Lockring.Locks, name}, nil)
  end
end
