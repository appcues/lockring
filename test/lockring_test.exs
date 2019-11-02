defmodule LockringTest.Resource do
  use GenServer
  def init(opts), do: {:ok, opts}
  def handle_call(:state, _from, state), do: {:reply, state, state}
  def handle_cast(:crash, _state), do: raise("this crash is deliberate")
end

defmodule LockringTest do
  use ExUnit.Case, async: true
  doctest Lockring

  test "lock a thing" do
    name = self()
    Lockring.new(name)
    assert {:ok, lock_ref, _resource} = Lockring.lock(name)
    assert :fail = Lockring.lock(name)
    assert :ok = Lockring.release(lock_ref)
    assert {:ok, lock_ref, _resource} = Lockring.lock(name)
  end

  test "locks are created on demand" do
    name = self()
    assert {:ok, lock_ref, _resource} = Lockring.lock(name)
    assert :fail = Lockring.lock(name)
  end

  test "lock pool" do
    name = self()
    Lockring.new(name, size: 5)
    assert {:ok, _lock_ref, :none} = Lockring.lock(name)
    assert {:ok, _lock_ref, :none} = Lockring.lock(name)
    assert {:ok, _lock_ref, :none} = Lockring.lock(name)
    assert {:ok, _lock_ref, :none} = Lockring.lock(name)
    assert {:ok, _lock_ref, :none} = Lockring.lock(name)
    assert :fail = Lockring.lock(name)
  end

  test "resource function" do
    name = self()
    Lockring.new(name, size: 2, resource: fn name, index -> {name, index} end)
    assert {:ok, _lock_ref, {^name, 1}} = Lockring.lock(name)
    assert {:ok, _lock_ref, {^name, 2}} = Lockring.lock(name)
    assert :fail = Lockring.lock(name)
  end

  test "resource genserver" do
    name = self()
    Lockring.new(name, size: 2, resource: {LockringTest.Resource, [foo: :bar]})

    assert {:ok, _lock_ref, pid1} = Lockring.lock(name)
    assert name == GenServer.call(pid1, :state)[:name]
    assert 1 == GenServer.call(pid1, :state)[:index]
    assert :bar == GenServer.call(pid1, :state)[:foo]

    assert {:ok, _lock_ref, pid2} = Lockring.lock(name)
    assert name == GenServer.call(pid2, :state)[:name]
    assert 2 == GenServer.call(pid2, :state)[:index]
    assert :bar == GenServer.call(pid2, :state)[:foo]
  end

  test "resource genserver dies and is replaced" do
    name = self()
    Lockring.new(name, size: 1, resource: {LockringTest.Resource, []})

    assert {:ok, _lock_ref, pid1} = Lockring.lock(name)
    assert :fail = Lockring.lock(name)

    GenServer.cast(pid1, :crash)
    Process.sleep(50)

    assert {:ok, _lock_ref, pid2} = Lockring.lock(name)
    assert pid1 != pid2
  end

  test "with_lock" do
    name = self()
    Lockring.new(name, size: 1, resource: fn name, index -> {name, index} end)
    assert {:ok, {name, 1}} == Lockring.with_lock(name, fn res -> res end)
  end

  test "with_lock wait_timeout" do
    name = self()
    Lockring.new(name, size: 1, resource: {LockringTest.Resource, []})

    spawn(fn ->
      Lockring.with_lock(name, fn _res -> Process.sleep(500) end)
    end)

    Process.sleep(50)
    assert {:error, _} = Lockring.with_lock(name, fn _res -> :ok end, wait_timeout: 100)
  end

  test "with_lock fun_timeout" do
    name = self()
    Lockring.new(name, size: 1, resource: {LockringTest.Resource, []})

    assert {:error, _} =
             Lockring.with_lock(name, fn _res -> Process.sleep(500) end, fun_timeout: 100)
  end

  test "lock is released if with_lock fun crashes" do
    name = self()
    assert {:error, _} = Lockring.with_lock(name, fn _ -> raise "crash" end)
    assert {:ok, _lock_ref, _resource} = Lockring.lock(name)
  end

  test "recovers from underflow" do
    name = self()
    Lockring.new(name, size: 1, resource: {LockringTest.Resource, []})
    Lockring.locks(name) |> :atomics.put(1, -5)

    assert {:ok, lock_ref, _resource} = Lockring.wait_for_lock(name)
    assert :fail = Lockring.lock(name)

    assert :ok = Lockring.release(lock_ref)
    assert {:ok, _lock_ref, _resource} = Lockring.lock(name)
  end

  test "bad resource" do
    name = self()

    output =
      try do
        Lockring.new(name, size: 1, resource: :wat)
      rescue
        _ -> :crash
      end

    assert :crash = output
  end
end
