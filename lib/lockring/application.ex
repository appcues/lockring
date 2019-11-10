defmodule Lockring.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, args) do
    Lockring.init(args)

    children = [
      {Lockring.Maker, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Lockring.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Lockring.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
