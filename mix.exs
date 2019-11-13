defmodule Lockring.MixProject do
  use Mix.Project

  def project do
    [
      app: :lockring,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Lockring.Application, []},
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc", only: [:dev, :test], runtime: false},
      {:freedom_formatter, "~> 1.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.11", only: :test},
    ]
  end
end
