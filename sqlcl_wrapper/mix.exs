defmodule SqlclWrapper.MixProject do
  use Mix.Project

  def project do
    [
      app: :sqlcl_wrapper,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SqlclWrapper.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.7"},
      {:porcelain, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.0"},
      {:jason, "~> 1.2"}
    ]
  end
end
