defmodule Convex.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :convex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Convex.Application, []}
    ]
  end

  defp aliases do
    [
      check: ["format", "compile", "test"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:websockex, git: "https://github.com/witchtails/websockex_wt.git", branch: "master"}
    ]
  end
end
