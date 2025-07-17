defmodule SqlclWrapper.MixProject do
  use Mix.Project

  def project do
    [
      app: :sqlcl_wrapper,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :hermes_mcp],
      mod: {SqlclWrapper.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.18"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.2"},
      {:hermes_mcp, "~> 0.12.1"},
      {:httpoison, "~> 2.1", only: [:dev, :test]},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
