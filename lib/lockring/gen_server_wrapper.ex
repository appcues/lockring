defmodule Lockring.GenServerWrapper do
  @moduledoc false

  ## The purpose of this module is to use pids of other GenServers as
  ## resources while ensuring crashes are handled properly: launching a new
  ## GenServer resource, installing it in the right pool, and releasing
  ## its lock.

  use GenServer

  def init(opts) do
    module = opts[:module]
    opts = opts[:opts]
    name = opts[:name]
    index = opts[:index]

    locks = Lockring.locks(name)

    :atomics.put(locks, index, -999)

    {:ok, pid} = GenServer.start_link(module, opts)
    Lockring.put_resource(name, index, pid)

    semaphore = :persistent_term.get({Lockring.Semaphore, name})
    :atomics.put(locks, index, semaphore)

    {:ok, opts}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
end
