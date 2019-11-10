defmodule Lockring.Maker do
  @moduledoc false

  use GenServer

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
        :ets.new(nil, [:set, :public, {:write_concurrency, true}, {:read_concurrency, true}])

      size = Lockring.config(:size, opts)
      locks = :atomics.new(size, [])
      index = :atomics.new(1, [])
      :atomics.put(index, 1, -1)

      :persistent_term.put({Lockring.Table, name}, table)
      :persistent_term.put({Lockring.Size, name}, size)
      :persistent_term.put({Lockring.Opts, name}, opts)
      :persistent_term.put({Lockring.Locks, name}, locks)
      :persistent_term.put({Lockring.Index, name}, index)

      Enum.each(1..size, &launch_resource(table, name, &1, opts))

      {:reply, :ok, state}
    rescue
      e -> {:reply, {:error, e}, state}
    end
  end

  defp launch_resource(table, name, index, opts) do
    case Lockring.config(:resource, opts) do
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
