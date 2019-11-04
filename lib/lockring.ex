defmodule Lockring do
  @moduledoc ~S"""
  Lockring is a mutex library for BEAM languages.

  Use it when you need exclusive access to a single resource or
  one of a pool of resources.

  These resources can be static data or GenServers. In the latter case,
  GenServer crashes are handled automatically, replacing the crashed server
  and releasing its lock.

  Lockring uses ETS tables and Erlang `:atomics` to coordinate locking,
  providing high scalability without the bottleneck and message-passing
  overhead of a GenServer-based system.
  """

  use Lockring.Debug

  @type name :: any
  @type index :: non_neg_integer
  @type lock_ref :: {name, index}
  @type resource :: any

  @table Application.get_env(:lockring, :ets_table, Lockring.Table)

  @delay Application.get_env(:lockring, :spin_delay)

  @defaults [
    size: Application.get_env(:lockring, :size, 1),
    timeout: 5000,
    wait_timeout: :infinity,
    fun_timeout: :infinity,
    resource: :none
  ]

  ## ETS data layout:
  ##
  ## {name, :opts} :: Keyword.t
  ## {name, :size} :: non_neg_integer
  ## {name, :locks} :: :atomics(size)
  ## {name, :index} :: :atomics(1)
  ## {name, :resource, index} :: any

  @doc ~S"""
  Creates a new Lockring pool.

  Options:

  * `:size` - The number of resources in this pool. Default 1.

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
  @spec new(name, Keyword.t()) :: :ok
  def new(name, opts \\ []) do
    size = :size |> config(opts)

    debug("Creating Lockring pool #{inspect(name)} of size #{size}.")

    insert_new!({name, :size}, size)
    insert_new!({name, :opts}, opts)

    locks = :atomics.new(size, [])
    insert_new!({name, :locks}, locks)

    index = :atomics.new(1, [])
    :atomics.put(index, 1, -1)
    insert_new!({name, :index}, index)

    for index <- 1..size do
      launch_resource(name, index, opts)
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
  @spec lock(name, Keyword.t()) :: {:ok, lock_ref, resource} | :fail | {:error, String.t()}
  def lock(name, opts \\ []) do
    case locks(name) do
      nil ->
        new(name, opts)
        lock(name, opts)

      locks ->
        index = next_index(name)

        case :atomics.add_get(locks, index, 1) do
          1 ->
            lock_ref = {name, index}
            debug("Locked #{inspect(lock_ref)}")
            resource = get_resource(name, index)
            {:ok, lock_ref, resource}

          n when n > 1 ->
            :atomics.sub(locks, index, 1)
            :fail

          n when n < 1 ->
            ## Something got screwed up, retry.
            ## Adding 1 is more effective than putting 0 because races
            ## here will be resolved naturally by release().
            lock(name, opts)
        end
    end
  end

  @doc ~S"""
  Releases a lock.
  """
  @spec release(lock_ref) :: :ok
  def release(lock_ref) do
    {name, index} = lock_ref
    debug("Released #{inspect(lock_ref)}")
    locks(name) |> :atomics.put(index, 0)
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
  @spec wait_for_lock(name, timeout) :: {:ok, lock_ref, resource} | :fail | {:error, String.t()}
  def wait_for_lock(name, timeout \\ :infinity, opts \\ []) do
    wait_until =
      case timeout do
        :infinity -> :infinity
        t -> now() + t
      end

    wait_for_lock_until(name, wait_until, opts)
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
  @spec with_lock(name, (resource -> any), Keyword.t()) :: {:ok, any} | {:error, String.t()}
  def with_lock(name, fun, opts \\ []) do
    timeout = :timeout |> config(opts)
    wait_timeout = :wait_timeout |> config(opts)
    fun_timeout = :fun_timeout |> config(opts)

    actual_wait_timeout =
      case {timeout, wait_timeout} do
        {nil, _} -> wait_timeout
        {:infinity, _} -> wait_timeout
        {_, :infinity} -> timeout
        {_, _} -> min(timeout, wait_timeout)
      end

    actual_wait_timeout =
      if actual_wait_timeout == :infinity do
        :infinity
      else
        max(0, actual_wait_timeout)
      end

    start_time = now()

    case wait_for_lock(name, actual_wait_timeout, opts) do
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

          actual_fun_timeout =
            case {timeout, fun_timeout} do
              {nil, _} -> fun_timeout
              {:infinity, _} -> fun_timeout
              {_, :infinity} -> timeout - elapsed
              {_, _} -> min(timeout - elapsed, fun_timeout)
            end

          actual_fun_timeout =
            if actual_fun_timeout == :infinity do
              :infinity
            else
              max(0, actual_fun_timeout)
            end

          case Task.yield(task, max(0, actual_fun_timeout)) do
            {:ok, {:task_error, e}} ->
              {:error, Exception.message(e)}

            {:ok, return_value} ->
              {:ok, return_value}

            nil ->
              Task.shutdown(task)
              ## FIXME destroy resource here?
              {:error, "fun_timeout reached"}
          end
        after
          release(lock_ref)
        end

      error ->
        error
    end
  end

  #### Private stuff below here

  @doc false
  def config(key, opts) do
    opts[key] || Application.get_env(:lockring, key, @defaults[key])
  end

  @doc false
  def now do
    :erlang.monotonic_time(:millisecond)
  end

  #### ETS helpers

  defp lookup(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_key, value}] -> value
      [] -> default
    end
  end

  defp insert(key, value) do
    :ets.insert(@table, {key, value})
  end

  defp insert!(key, value) do
    case insert(key, value) do
      true -> true
      false -> raise "insert! couldn't (key: #{inspect(key)}"
    end
  end

  defp insert_new(key, value) do
    :ets.insert_new(@table, {key, value})
  end

  defp insert_new!(key, value) do
    case insert_new(key, value) do
      true -> true
      false -> raise "insert_new! couldn't (key: #{inspect(key)}"
    end
  end

  ## Data helpers

  defp get_resource(name, index) do
    case lookup({name, :resource, index}) do
      {:resource, r} -> r
      _ -> get_resource(name, index)
    end
  end

  @doc false
  def put_resource(name, index, resource) do
    insert!({name, :resource, index}, {:resource, resource})
  end

  defp index(name) do
    lookup({name, :index})
  end

  @doc false
  def locks(name) do
    lookup({name, :locks})
  end

  defp size(name) do
    lookup({name, :size})
  end

  defp next_index(name) do
    n = index(name) |> :atomics.add_get(1, 1)
    rem(n, size(name)) + 1
  end

  ## Other helpers

  defp wait_for_lock_until(name, until, opts) do
    case Lockring.lock(name, opts) do
      {:ok, _lock_ref, _resource} = success ->
        success

      :fail ->
        if until == :infinity || now() < until do
          if nil != @delay, do: Process.sleep(@delay)
          wait_for_lock_until(name, until, opts)
        else
          {:error, "wait_timeout reached"}
        end
    end
  end

  defp launch_resource(name, index, opts) do
    case config(:resource, opts) do
      :none ->
        put_resource(name, index, :none)

      fun when is_function(fun) ->
        put_resource(name, index, fun.(name, index))

      {module, module_opts} ->
        new_module_opts = [{:name, name}, {:index, index} | module_opts]

        wrapper_opts = [
          module: module,
          opts: new_module_opts,
          name: name,
          index: index
        ]

        DynamicSupervisor.start_child(Lockring.DynamicSupervisor, %{
          id: {Lockring.DynamicSupervisor, name, index},
          start: {Lockring.GenServerWrapper, :start_link, [wrapper_opts]},
          restart: :permanent,
          type: :worker,
          shutdown: :brutal_kill
        })

      other ->
        raise ArgumentError, "unknown value for :resource -- #{inspect(other)}"
    end
  end
end
