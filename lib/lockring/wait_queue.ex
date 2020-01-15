defmodule Lockring.WaitQueue do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc ~S"""
  A caller sends this message via `Lockring.wait_for_lock/3` to indicate
  it wants to await a lock.

  Replies `:fail` if queue is full, `:ok` otherwise.
  """
  @spec await(pid, timeout) :: :ok | :fail
  def await(wait_queue, timeout_at \\ :infinity) do
    GenServer.call(wait_queue, {:await, self(), timeout_at})
  end

  @doc ~S"""
  This message is sent by `Lockring.release/1` when the wait queue flag
  is 1 (i.e., the queue is not empty).

  If there is an eligible waiting process, send it `lock_ref` and `resource`;
  otherwise release the lock.
  """
  @spec next(pid, Lockring.lock_ref(), Lockring.resource()) :: :ok
  def next(wait_queue, lock_ref, resource) do
    GenServer.cast(wait_queue, {:next, lock_ref, resource})
  end

  @impl true
  def init(args) do
    size = Lockring.Config.config(:wait_queue, args[:opts])

    state = %{
      size: size,
      name: args[:name],
      index: args[:index],
      flags: args[:flags],
      waiting: [],
      wait_count: 0,
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:await, pid, timeout_at}, _from, state) do
    if state.wait_count >= state.size do
      {:reply, :fail, state}
    else
      waiting = [{pid, timeout_at} | state.waiting]
      wait_count = state.wait_count + 1
      :atomics.put(state.flags, state.index, 1)

      {:reply, :ok,
       %{state | waiting: waiting, wait_count: state.wait_count + 1}}
    end
  end

  @impl true
  def handle_cast({:next, lock_ref, resource}, state) do
    case state.waiting do
      [{pid, timeout_at} | rest] ->
        new_state = %{state | waiting: rest, wait_count: state.wait_count - 1}

        if timeout_at == :infinity || timeout_at <= now() do
          send(pid, {Lockring.GoAhead, lock_ref, resource})
          {:noreply, new_state}
        else
          handle_cast({:next, lock_ref, resource}, new_state)
        end

      [] ->
        :atomics.put(state.flags, state.index, 0)
        Lockring.release(lock_ref)
        {:noreply, state}
    end
  end

  defp now, do: :erlang.monotonic_time(:millisecond)
end
