defmodule Lockring.Maker do
  @moduledoc false

  use GenServer
  import Lockring.Config, only: [config: 2]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def handle_call({:new, name, opts}, _from, state) do
    try do
      table =
        :ets.new(nil, [
          :set,
          :public,
          {:write_concurrency, true},
          {:read_concurrency, true},
        ])

      size = config(:size, opts)
      semaphore = config(:semaphore, opts)

      locks = :atomics.new(size, [])
      Enum.each(1..size, &:atomics.put(locks, &1, semaphore))

      index = :atomics.new(1, [])
      :atomics.put(index, 1, -1)

      :persistent_term.put({Lockring.Table, name}, table)
      :persistent_term.put({Lockring.Size, name}, size)
      :persistent_term.put({Lockring.Semaphore, name}, semaphore)
      :persistent_term.put({Lockring.Opts, name}, opts)
      :persistent_term.put({Lockring.Locks, name}, locks)
      :persistent_term.put({Lockring.Index, name}, index)

      wait_queue_flags = :atomics.new(size, [])
      :persistent_term.put({Lockring.WaitQueueFlags, name}, wait_queue_flags)

      wait_queues =
        Enum.reduce(1..size, %{}, fn index, acc ->
          pid = launch_wait_queue(name, index, wait_queue_flags, opts)
          Map.put(acc, index, pid)
        end)

      :persistent_term.put({Lockring.WaitQueues, name}, wait_queues)

      Enum.each(1..size, &launch_resource(table, name, &1, opts))

      {:reply, :ok, state}
    rescue
      e -> {:reply, {:error, e}, state}
    end
  end

  defp launch_wait_queue(name, index, flags, opts) do
    wait_queue_opts = [
      name: name,
      index: index,
      flags: flags,
      opts: opts,
    ]

    {:ok, pid} =
      DynamicSupervisor.start_child(Lockring.DynamicSupervisor, %{
        id: {Lockring.WaitQueue, name, index},
        start: {Lockring.WaitQueue, :start_link, [wait_queue_opts]},
        restart: :permanent,
        type: :worker,
        shutdown: :brutal_kill,
      })

    pid
  end

  defp launch_resource(table, name, index, opts) do
    case config(:resource, opts) do
      :none ->
        Lockring.put_resource(name, index, :none)

      fun when is_function(fun) ->
        Lockring.put_resource(name, index, fun.(name, index))

      {module, module_opts} ->
        new_module_opts = [{:name, name}, {:index, index} | module_opts]

        wrapper_opts = [
          module: module,
          opts: new_module_opts,
          table: table,
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
