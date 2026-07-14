defmodule Mix.Tasks.ObanClaude.Install.Docs do
  @moduledoc false

  def short_doc, do: "Scaffold a runnable SQLite-backed oban_claude setup."

  def example, do: "mix oban_claude.install"

  def long_doc do
    """
    #{short_doc()}

    Composes `oban.install` (steering it to SQLite and the `Oban.Engines.Lite`
    engine) and adds the claude-specific pieces on top: a sample worker, a
    telemetry logger, and a boot-time demo enqueue so `iex -S mix` shows a job
    run end to end.

    ## Example

        # into a fresh project
        mix igniter.new my_app --install oban_claude

        # or into an existing project
        mix igniter.install oban_claude

    Then:

        iex -S mix

    ## What it produces

      * an Ecto SQLite3 repo (module, dev/test config, supervision child)
      * Oban configured with `Oban.Engines.Lite`, its migration, and supervision
      * a sample `ObanClaude.Worker` on a `:claude` queue
      * a telemetry logger + a dev-only boot enqueue (the "watch" demo)

    The sample worker ships with a stubbed, offline `query_fun` so the demo runs
    without a real (paid) claude call. Delete that one option to call claude.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ObanClaude.Install do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.{Application, Config, Module}

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :oban_claude,
        example: __MODULE__.Docs.example(),
        composes: ["oban.install"],
        adds_deps: [{:oban, "~> 2.23"}, {:ecto_sqlite3, "~> 0.17"}],
        installs: [],
        schema: [],
        defaults: [],
        aliases: [],
        positional: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Application.app_name(igniter)
      repo = Module.module_name(igniter, "Repo")
      worker = Module.module_name(igniter, "SampleClaudeWorker")
      demo = Module.module_name(igniter, "ObanClaudeDemo")

      igniter
      |> ensure_sqlite_repo(app_name, repo)
      |> Igniter.compose_task("oban.install", [
        "--engine",
        "Oban.Engines.Lite",
        "--repo",
        inspect(repo)
      ])
      |> configure_claude_queue(app_name)
      |> create_worker(worker)
      |> create_demo(app_name, worker, demo)
      |> Application.add_new_child(demo, after: [Oban])
      |> Igniter.add_notice(notice(worker))
    end

    # A SQLite repo has to exist before `oban.install` runs (it errors when no
    # repo is found), so create the module, its config, and its supervision
    # child up front.
    defp ensure_sqlite_repo(igniter, app_name, repo) do
      db_dev = "#{app_name}_dev.db"
      db_test = "#{app_name}_test.db"

      igniter
      |> Module.create_module(repo, """
      use Ecto.Repo, otp_app: #{inspect(app_name)}, adapter: Ecto.Adapters.SQLite3
      """)
      |> Config.configure_new("config.exs", app_name, [:ecto_repos], [repo])
      |> Config.configure_new("dev.exs", app_name, [repo], database: db_dev, pool_size: 5)
      |> Config.configure_new("test.exs", app_name, [repo],
        database: db_test,
        pool_size: 5,
        pool: Ecto.Adapters.SQL.Sandbox
      )
      |> Application.add_new_child(repo)
    end

    # `oban.install` writes `queues: [default: 10]`; add the `:claude` queue the
    # sample worker runs on. Use an `:updater` that *merges* `claude: 5` into the
    # existing keyword list rather than replacing it -- a bare `configure/5`
    # would overwrite an app's other queues (mailers, events, ...) and silently
    # stop them processing on the next boot.
    defp configure_claude_queue(igniter, app_name) do
      Config.configure(
        igniter,
        "config.exs",
        app_name,
        [Oban, :queues],
        [default: 10, claude: 5],
        updater: fn zipper ->
          Igniter.Code.Keyword.set_keyword_key(zipper, :claude, 5, fn z -> {:ok, z} end)
        end
      )
    end

    defp create_worker(igniter, worker) do
      Module.create_module(igniter, worker, ~S'''
      @moduledoc """
      A sample oban_claude worker.

      It ships with a stubbed, offline `query_fun` so the boot demo runs without
      a real (paid) claude call. To call claude for real, delete the `query_fun`
      option from the `use` below.
      """
      # `worktree: true` isolates each real run in its own git worktree (recommended
      # for full-auto workers that write to a repo). It needs `working_dir` to be a
      # git repo; the offline demo ignores it, so it is harmless until you go live.
      #
      # Fleet rails (see the "Agent worker patterns" guide): `max_attempts` is
      # explicit because every retry is a fresh paid run -- use 1 for a mutating
      # worker; `timeout` bounds a wedged CLI; add `forcola` + the runner config
      # so a timed-out or cancelled run is actually killed, not orphaned.
      use ObanClaude.Worker,
        queue: :claude,
        max_attempts: 3,
        args: ObanClaude.Args.defaults(worktree: true, timeout: :timer.minutes(10)),
        query_fun: &__MODULE__.demo_query/2

      require Logger

      @impl ObanClaude.Worker
      def handle_result(result, _job) do
        Logger.info("[oban_claude] sample job result: #{inspect(result.result)}")
        :ok
      end

      @doc false
      # Offline stand-in for `ClaudeWrapper.query/2`. Delete the `query_fun`
      # option above to run the real claude CLI instead.
      def demo_query(prompt, _opts) do
        {:ok, %ClaudeWrapper.Result{result: "demo run for: #{prompt}", is_error: false, cost_usd: 0.0}}
      end
      ''')
    end

    # The "watch" demo: a supervised process that attaches a telemetry logger for
    # the run events and, in dev, enqueues one sample job on boot so `iex -S mix`
    # immediately shows a job run. Delete this module (and its child) for a real
    # app.
    defp create_demo(igniter, app_name, worker, demo) do
      Module.create_module(igniter, demo, """
      @moduledoc \"\"\"
      Watch demo for oban_claude: logs run telemetry and enqueues one sample job
      on boot (dev only). Delete this module and its child in your Application to
      remove the demo.

      > #### Telemetry carries sensitive data {: .warning}
      >
      > The `:args` (prompt, system prompt, meta), `:result`, and `:error`
      > metadata on these events can contain prompts and raw CLI stdout/stderr.
      > This demo logs only the error *kind* and the cost; redact before shipping
      > telemetry to a log aggregator.
      \"\"\"
      use GenServer

      require Logger

      @events [[:oban_claude, :run, :stop], [:oban_claude, :run, :exception]]

      def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(_) do
        :telemetry.attach_many("#{app_name}-oban-claude", @events, &__MODULE__.handle_event/4, nil)
        # Enqueue after init returns, so a boot before `mix ecto.migrate` does not
        # crash the app on a missing table (the enqueue is guarded below).
        {:ok, nil, {:continue, :maybe_enqueue}}
      end

      @impl true
      def handle_continue(:maybe_enqueue, state) do
        if dev?(), do: enqueue_sample()
        {:noreply, state}
      end

      # Guarded so this never crashes in a release, where Mix is unavailable.
      defp dev?, do: Code.ensure_loaded?(Mix) and Mix.env() == :dev

      @impl true
      def terminate(_reason, _state) do
        :telemetry.detach("#{app_name}-oban-claude")
        :ok
      end

      def handle_event([:oban_claude, :run, :stop], meas, _meta, _) do
        Logger.info("[oban_claude] run finished in \#{System.convert_time_unit(meas.duration, :native, :millisecond)}ms, cost $\#{meas.cost_usd}")
      end

      def handle_event([:oban_claude, :run, :exception], meas, meta, _) do
        # Log the error KIND, not the whole %Error{}: its :stdout/:stderr can
        # carry raw CLI output (auth diagnostics, file paths, repo content).
        kind =
          case meta.error do
            %ClaudeWrapper.Error{kind: k} -> k
            other -> inspect(other)
          end

        Logger.warning("[oban_claude] run errored (\#{kind}), cost $\#{meas.cost_usd}")
      end

      defp enqueue_sample do
        ObanClaude.Args.new(prompt: "hello from oban_claude")
        |> #{inspect(worker)}.new()
        |> Oban.insert()
      rescue
        e ->
          Logger.warning("[oban_claude] demo enqueue skipped -- run mix ecto.migrate first (\#{Exception.message(e)})")
      end
      """)
    end

    defp notice(worker) do
      """
      oban_claude is installed. Next:

        mix ecto.create
        mix ecto.migrate
        iex -S mix

      On boot (in dev) a sample job is enqueued and #{inspect(worker)} runs it
      offline, logging via telemetry. To call claude for real, delete the
      `query_fun` option in #{inspect(worker)}.

      Before running a fleet unattended, set up the fleet rails (see the
      "Agent worker patterns" guide):

        * add {:forcola, "~> 0.3"} and `config :claude_wrapper, runner:
          ClaudeWrapper.Runner.Forcola` so a timed-out/cancelled run is killed,
          not orphaned;
        * add {Oban.Plugins.Lifeline, rescue_after: <above your args timeout>}
          to the Oban `plugins:` so jobs orphaned by a deploy are rescued;
        * keep `max_attempts` low (retries are paid) and raise
          `shutdown_grace_period` above your worst-case run.
      """
    end
  end
else
  defmodule Mix.Tasks.ObanClaude.Install do
    @shortdoc "Scaffold a runnable SQLite-backed oban_claude setup (requires Igniter)."
    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix oban_claude.install requires Igniter, which is not available.

      Add it to your deps and re-run:

          {:igniter, "~> 0.6", only: [:dev, :test]}
      """)

      exit({:shutdown, 1})
    end
  end
end
