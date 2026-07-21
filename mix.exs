defmodule ObanClaude.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/genagent/oban_claude"

  def project do
    [
      app: :oban_claude,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],
      description:
        "Run Claude Code jobs on an Oban queue: an Oban.Worker over claude_wrapper that maps claude's typed result/error onto Oban return values.",
      package: package(),
      name: "oban_claude",
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "guides/getting_started.md",
          "guides/agent_worker_patterns.md",
          "guides/agent_lifecycle.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          Guides: [
            "guides/getting_started.md",
            "guides/agent_worker_patterns.md",
            "guides/agent_lifecycle.md"
          ]
        ],
        groups_for_modules: [
          "Agent lifecycle": [
            ObanClaude.Agent,
            ObanClaude.Agent.Instance,
            ObanClaude.Agent.Job,
            ObanClaude.Agent.Supervisor,
            ObanClaude.Agent.Tick
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:oban, "~> 2.23"},
      # The seam onto `claude -p`: a typed Result/Error and query/2. Pinned to
      # the 0.14.x line: this library hardcodes the wrapper contract (the
      # @passthrough keys, the permission_mode/effort/hermetic vocabularies, and
      # the Outcome error kinds), and claude_wrapper has shipped breaking changes
      # in 0.x minors -- bump deliberately, re-verifying those lists per release.
      # (0.14.0's breaking changes are all in Commands.*/Bundled/DuplexSession,
      # none of which this library consumes; query/2 + Result/Error are unchanged.)
      {:claude_wrapper, "~> 0.14.0"},
      # Schema for `ObanClaude.Args`: validates the builder's options and
      # generates their documentation from a single source of truth.
      {:nimble_options, "~> 1.1"},
      # Used to verify `:meta` values are JSON-clean at build time (the same
      # encoder Oban serializes args with), so a bad value fails at construction
      # rather than deep inside `Oban.insert`.
      {:jason, "~> 1.4"},
      # Backs the `mix oban_claude` command tree (run/doctor/args): parsing,
      # validation, help, and completion from one declarative command definition.
      # A regular dep (the tasks are user-facing, unlike the dev-only Igniter
      # installer), but zero-runtime-dependencies, so it stays light.
      {:cheer, "~> 0.2"},
      # `~> 1.3`, not `~> 1.2`: oban `~> 2.23` already requires telemetry 1.3+,
      # so a 1.2.x floor is unsatisfiable in any valid resolution.
      {:telemetry, "~> 1.3"},
      # Dev/test only: powers the `mix oban_claude.install` Igniter task. The
      # task module only compiles when Igniter is loaded, so it never ships as a
      # runtime dependency of the library.
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      # Dev/test only: backs the SQLite (Lite) Oban engine used by the
      # dev/playground.exs harness. Never a runtime dep of the library.
      {:ecto_sqlite3, "~> 0.17", only: [:dev, :test]},
      # Static analysis. Never runtime deps.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      # Hex's default file set omits guides/ and examples/, but the README (the
      # hexdocs landing page) tells readers to `mix run examples/<name>.exs` --
      # so ship them.
      files:
        ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md SPEC.md guides examples),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/oban_claude/changelog.html"
      }
    ]
  end
end
