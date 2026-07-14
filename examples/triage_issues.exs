# examples/triage_issues.exs
#
# Dogfood: an `ObanClaude.Worker` triages real GitHub issues. Each open issue
# becomes a claude job on the `:triage` queue; the worker runs claude with a JSON
# schema and gets back a typed `{label, priority, summary}`.
#
# It is READ-ONLY. The worker prints the verdict and stops. It never writes back
# to GitHub: writing labels or comments is a *sink's* job, and the sink
# (`oban_github`) lives elsewhere. `oban_claude` returns the verdict; consuming
# it is someone else's concern. That boundary is the whole point of the package,
# and this example stays on the right side of it.
#
#   mix run examples/triage_issues.exs           # offline: deterministic stub, no paid calls
#   mix run examples/triage_issues.exs --live     # real, paid claude calls (haiku)
#
# Issues are fetched with `gh` (a read) in both modes; `--live` only controls
# whether claude is real or a keyword stub. If `gh` is unavailable, a small baked
# issue list is used so the example always runs.

live? = "--live" in System.argv()
Application.put_env(:oban_claude_triage, :live, live?)

import Ecto.Query, only: [from: 2]

# --- Fetch open issues (real via gh, baked fallback) ------------------------
repo = "genagent/oban_claude"

baked = [
  %{
    "number" => 901,
    "title" => "Worker drops job args when default args map is large",
    "body" =>
      "Under load some jobs run with only the worker defaults; the per-job args go missing. Looks like a merge bug."
  },
  %{
    "number" => 902,
    "title" => "Document the :classifier override in the README",
    "body" =>
      "The README mentions the classifier but never shows how to pass a custom one to use ObanClaude.Worker."
  },
  %{
    "number" => 903,
    "title" => "Add a test for the unknown permission_mode raise",
    "body" =>
      "coerce/2 raises ArgumentError on an unknown permission_mode; there should be a test pinning the message."
  }
]

# `gh` absent on this host (e.g. CI): System.cmd/3 would raise :enoent, not
# return, so guard with find_executable/1 first -- then a live host without gh
# falls back to the baked list instead of crashing, as the header promises.
issues =
  if System.find_executable("gh") do
    case System.cmd(
           "gh",
           ~w(issue list --repo #{repo} --state open --json number,title,body --limit 6),
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, [_ | _] = list} -> list
          _ -> baked
        end

      _ ->
        baked
    end
  else
    baked
  end

source = if issues == baked, do: "baked sample issues (gh unavailable)", else: "#{repo} (live gh)"

# --- The triage worker ------------------------------------------------------
# The schema (the typed verdict claude must return) is a module attribute so the
# `use ObanClaude.Worker, args: ...` default can reference it.
defmodule TriageJob do
  @schema_json Jason.encode!(%{
                 "type" => "object",
                 "additionalProperties" => false,
                 "properties" => %{
                   "label" => %{"enum" => ~w(bug enhancement documentation test chore question)},
                   "priority" => %{"enum" => ~w(high medium low)},
                   "summary" => %{"type" => "string"}
                 },
                 "required" => ~w(label priority summary)
               })

  @system_prompt """
  You triage GitHub issues. Given one issue, return a JSON object with:
    - label: one of bug, enhancement, documentation, test, chore, question
    - priority: one of high, medium, low
    - summary: a one-line summary, at most 12 words
  Base the verdict only on the issue text.
  """

  use ObanClaude.Worker,
    queue: :triage,
    max_attempts: 1,
    query_fun: &__MODULE__.query/2,
    args: %{
      "model" => "haiku",
      "max_turns" => 3,
      "system_prompt" => @system_prompt,
      "json_schema" => @schema_json
    }

  alias ClaudeWrapper.Result

  # The seam's :query_fun. Real claude under --live, a deterministic stub
  # otherwise, so `mix run` is free and offline by default.
  def query(prompt, opts) do
    if Application.get_env(:oban_claude_triage, :live, false) do
      ClaudeWrapper.query(prompt, opts)
    else
      stub(prompt)
    end
  end

  # handle_result/2 only runs on a successful claude call. Wrap perform/1 (it is
  # overridable) so a failed call surfaces its Oban verdict instead of the worker
  # going silent. A real sink would route these to a dead-letter or alert path.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => number}} = job) do
    case super(job) do
      :ok ->
        :ok

      other ->
        IO.puts("  ##{number} no verdict (claude call failed): #{inspect(other)}")
        other
    end
  end

  # Read-only dispose: print the typed verdict. No GitHub write -- that is a
  # sink's job (oban_github), not oban_claude's.
  @impl ObanClaude.Worker
  def handle_result(result, %Oban.Job{args: %{"number" => number, "title" => title}}) do
    case ObanClaude.structured(result) do
      %{"label" => label, "priority" => priority, "summary" => summary} ->
        tag = String.pad_trailing("[#{label}/#{priority}]", 22)
        IO.puts("  ##{number} #{tag} #{summary}\n        (#{title})")

      _ ->
        IO.puts("  ##{number} (no structured output)")
    end

    :ok
  end

  # Deterministic offline stand-in for a --json-schema run: claude would return
  # this object; the stub fabricates it by keyword-matching the issue text.
  defp stub(prompt) do
    {label, priority} = classify(prompt)

    summary =
      prompt
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.replace(~r/^Issue #\d+:\s*/, "")
      |> String.slice(0, 60)

    object = %{"label" => label, "priority" => priority, "summary" => summary}
    {:ok, %Result{result: "", is_error: false, extra: %{"structured_output" => object}}}
  end

  defp classify(text) do
    t = String.downcase(text)

    cond do
      t =~ "silently" or t =~ "crash" or t =~ "data loss" or t =~ "drops" ->
        {"bug", "high"}

      t =~ "fix:" or t =~ " bug" ->
        {"bug", "medium"}

      t =~ "test:" or t =~ " test " or t =~ "live test" ->
        {"test", "medium"}

      t =~ "release" or t =~ "chore:" or t =~ "automation" or t =~ "publish" ->
        {"chore", "medium"}

      t =~ "docs:" or t =~ "readme" or t =~ "document" ->
        {"documentation", "low"}

      true ->
        {"enhancement", "low"}
    end
  end
end

# --- Boot a throwaway SQLite Oban (same harness as the other examples) -------
db_path = Path.join(System.tmp_dir!(), "oban_claude_triage.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule TriageRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, TriageRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule TriageMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

{:ok, _} = TriageRepo.start_link()
Ecto.Migrator.up(TriageRepo, 1, TriageMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: TriageRepo,
    engine: Oban.Engines.Lite,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [triage: 3]
  )

# --- Enqueue one triage job per issue ---------------------------------------
mode = if live?, do: "LIVE (real haiku calls)", else: "offline (deterministic stub)"
IO.puts("\nTriaging #{length(issues)} issues from #{source}")
IO.puts("Mode: #{mode}. Read-only: prints verdicts, writes nothing back.\n")

for %{"number" => number, "title" => title} = issue <- issues do
  body = Map.get(issue, "body", "") || ""

  args = %{
    "prompt" => "Issue ##{number}: #{title}\n\n#{body}",
    "number" => number,
    "title" => title
  }

  {:ok, _} = args |> TriageJob.new() |> Oban.insert()
end

# --- Wait for the queue to settle -------------------------------------------
# Real claude calls take seconds each; the stub is instant. Give live mode a
# real deadline so the script does not exit before the jobs reach
# handle_result/2. Note that exiting does NOT kill in-flight CLI processes under
# the default runner -- it orphans them (they keep running); use the Forcola
# runner for a fleet. See the "Process lifecycle" fleet-safety guide section.
terminal = ~w(completed cancelled discarded)
total = length(issues)
deadline_ms = if live?, do: 180_000, else: 10_000
poll_ms = 500

count_done = fn ->
  TriageRepo.all(from(j in "oban_jobs", select: j.state))
  |> Enum.count(&(&1 in terminal))
end

settled =
  Enum.reduce_while(1..div(deadline_ms, poll_ms), 0, fn i, _ ->
    Process.sleep(poll_ms)
    done = count_done.()
    if live? and rem(i, 10) == 0 and done < total, do: IO.puts("  ...waiting (#{done}/#{total})")
    if done >= total, do: {:halt, done}, else: {:cont, done}
  end)

if settled < total do
  IO.puts("\n#{settled}/#{total} jobs settled before the #{div(deadline_ms, 1000)}s deadline.")
end

IO.puts("\nDone. Verdicts above are advisory only; nothing was written to GitHub.")
