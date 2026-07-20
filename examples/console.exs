# examples/console.exs
#
# A local "Claude console": a real, SQLite-backed Oban queue you drive from iex.
# Loaded by .iex.exs. Boot it once, then enqueue prompts and watch jobs run real
# claude calls and print their results.
#
#   iex -S mix
#   ObanClaude.Console.start()
#   ObanClaude.Console.run("Summarize what an Oban queue is in one sentence.")
#   ObanClaude.Console.jobs()
#
# Each run/1 is a real, paid claude call (model haiku). The same offline
# SQLite-backed Oban setup as examples/playground.exs, but driven interactively.

defmodule ObanClaude.Console do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  @db Path.join(System.tmp_dir!(), "oban_claude_console.db")

  defmodule Repo do
    use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
  end

  defmodule Migration do
    use Ecto.Migration
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  # A preconfigured console worker: the model is baked in via :args, so a job is
  # just the prompt. handle_result/2 prints the result as the job completes.
  defmodule Worker do
    use ObanClaude.Worker, queue: :console, max_attempts: 1, args: %{"model" => "haiku"}

    # handle_result/2 runs only on a successful claude call. Wrap perform/1
    # (overridable) so a failed/cancelled run prints its Oban verdict instead of
    # the job going silent -- same pattern as examples/triage_issues.exs.
    @impl Oban.Worker
    def perform(%Oban.Job{id: id} = job) do
      case super(job) do
        :ok ->
          :ok

        other ->
          IO.puts("\n[job #{id}] no result (claude call failed): #{inspect(other)}")
          other
      end
    end

    @impl ObanClaude.Worker
    def handle_result(result, %Oban.Job{id: id, args: args}) do
      IO.puts("\n[job #{id}] #{inspect(args["prompt"])}")
      IO.puts("  -> #{String.trim(result.result)}")
      IO.puts("  (cost $#{result.cost_usd || 0.0}, #{result.num_turns || 0} turn(s))")
      :ok
    end
  end

  @doc "Boot the local SQLite-backed Oban queue. Call once per iex session."
  def start do
    Application.put_env(:oban_claude, Repo,
      database: @db,
      pool_size: 1,
      busy_timeout: 5_000,
      log: false
    )

    for suffix <- ["", "-shm", "-wal"], do: File.rm(@db <> suffix)
    {:ok, _} = Repo.start_link()
    Ecto.Migrator.up(Repo, 1, Migration, log: false)

    {:ok, _} =
      Oban.start_link(
        repo: Repo,
        engine: Oban.Engines.Lite,
        notifier: Oban.Notifiers.PG,
        peer: Oban.Peers.Isolated,
        plugins: [],
        # :agents backs ObanClaude.Agent's default worker, so the console is
        # also the barebones way to drive a live agent from iex.
        queues: [console: 1, agents: 1]
      )

    {:ok, _} = ObanClaude.Agent.Supervisor.start_link()

    IO.puts(~s|console up. run("a prompt") to enqueue, jobs() to list,|)
    IO.puts(~s|or ObanClaude.Agent.start_agent("a1") for a live agent on the :agents queue.|)
    :ok
  end

  @doc ~s|Enqueue a prompt as a job. Extra args (e.g. %{"model" => "sonnet"}) override the defaults.|
  def run(prompt, args \\ %{}) when is_binary(prompt) do
    {:ok, job} = args |> Map.put("prompt", prompt) |> Worker.new() |> Oban.insert()
    IO.puts("enqueued job #{job.id}")
    job.id
  end

  @doc "List the most recent jobs and their states."
  def jobs do
    Repo.all(
      from(j in "oban_jobs", select: {j.id, j.state, j.attempt}, order_by: [asc: j.id], limit: 20)
    )
    |> Enum.each(fn {id, state, attempt} ->
      IO.puts("  ##{id}  #{String.pad_trailing(state, 10)} attempt #{attempt}")
    end)
  end
end
