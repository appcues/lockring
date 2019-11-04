defmodule Lockring.Debug do
  @moduledoc false

  defmacro __using__(opts) do
    if Application.get_env(:lockring, :debug) do
      quote do
        require Logger
        defp debug(msg), do: Logger.debug(msg)
      end
    else
      quote do
        defp debug(_msg), do: :ok
      end
    end
  end
end
