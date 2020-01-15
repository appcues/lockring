defmodule Lockring.Config do
  @moduledoc false

  @defaults [
    spin_delay: 5,
    size: 1,
    wait_queue: 10,
    semaphore: 1,
    resource: :none,
    timeout: 5000,
    wait_timeout: :infinity,
    fun_timeout: :infinity
  ]

  defp default(key), do: @defaults[key]

  def config(key, opts \\ []) do
    cond do
      Keyword.has_key?(opts, key) -> opts[key]
      :else -> Application.get_env(:lockring, key, default(key))
    end
  end
end
