defmodule Convex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/celados/convex"

  def project do
    [
      app: :convex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      description: "Pure Elixir client for the Convex backend platform.",
      source_url: @source_url,
      homepage_url: "https://convex.dev",
      docs: [
        main: "Convex",
        extras: ["README.md", "LICENSE"]
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
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
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "ex_dna",
        "test --exclude integration"
      ],
      "check.ci": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna",
        "test --exclude integration"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"},

      # Dev/test tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false}
    ]
  end
end
