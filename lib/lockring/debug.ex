defmodule Lockring.Debug do
  @moduledoc false

  defmacro __using__(opts) do
    if opts[:debug] || Application.get_env(:lockring, :debug) do
      quote do
        require Logger

        defp debug(msg) when is_binary(msg) do
          Logger.debug("Lockring: " <> msg)
        end

        defp debug(fun) when is_function(fun) do
          Logger.debug(fn -> "Lockring: " <> fun.() end)
        end

        defp debug(term) do
          Logger.debug("Lockring: " <> inspect(term))
        end
      end
    else
      quote do
        defp debug(_msg), do: :ok
      end
    end
  end
end
