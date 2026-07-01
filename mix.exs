defmodule ObanClaude.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/genagent/oban_claude"

  def project do
    [
      app: :oban_claude,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Run Claude Code jobs on an Oban queue: an Oban.Worker over claude_wrapper that maps claude's typed result/error onto Oban return values.",
      package: package(),
      name: "oban_claude",
      source_url: @source_url,
      docs: [
        main: "ObanClaude",
        source_ref: "v#{@version}",
        extras: ["README.md", "CHANGELOG.md"]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:oban, "~> 2.23"},
      # The seam onto `claude -p`: a typed Result/Error and query/2.
      {:claude_wrapper, "~> 0.11.0"},
      # Schema for `ObanClaude.Args`: validates the builder's options and
      # generates their documentation from a single source of truth.
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      # Dev/test only: powers the `mix oban_claude.install` Igniter task. The
      # task module only compiles when Igniter is loaded, so it never ships as a
      # runtime dependency of the library.
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Dev/test only: backs the SQLite (Lite) Oban engine used by the
      # dev/playground.exs harness. Never a runtime dep of the library.
      {:ecto_sqlite3, "~> 0.17", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
