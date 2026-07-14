# Getting started

This walks you from an empty directory to a running claude worker on an Oban
queue -- end to end, on SQLite, no Postgres or Docker. By the end you enqueue a
job and watch it run.

There is a faster path: the [Igniter installer](readme.html#install)
scaffolds all of this in one command. This guide does it by hand so you
understand each piece; skip to [step 7](#7-your-first-worker) if the
installer already set up the project.

## Requirements

- **Elixir `~> 1.20`** on **OTP 29** -- what this library is built and tested on.
- The **`claude` CLI, installed and authenticated** -- it is what actually runs
  (via `claude_wrapper`). Steps 1-8 are fully offline (claude is stubbed), but
  step 9 makes a real call, so install the CLI and sign in first and run
  `claude doctor` to confirm. Without it, your first real job dead-letters as
  `{:cancel, :binary_not_found}` or `{:cancel, :auth}`.

## 1. A new project

```bash
mix new my_app --sup
cd my_app
```

The `--sup` gives you a supervision tree (`lib/my_app/application.ex`), which is
where Oban and the repo will start.

## 2. Dependencies

Add three deps in `mix.exs` -- `oban_claude`, `oban`, and the SQLite adapter:

```elixir
defp deps do
  [
    {:oban_claude, "~> 0.1"},
    {:oban, "~> 2.23"},
    {:ecto_sqlite3, "~> 0.17"}
  ]
end
```

```bash
mix deps.get
```

If an existing project's lockfile pins an older Oban, run `mix deps.update oban`
(oban_claude requires `~> 2.23`).

## 3. An Ecto repo

Oban stores jobs in a database. Create a SQLite-backed repo at
`lib/my_app/repo.ex`:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
end
```

Point the app at it and give it a database file (`config/config.exs`):

```elixir
import Config

config :my_app, ecto_repos: [MyApp.Repo]
config :my_app, MyApp.Repo, database: "my_app_dev.db"
```

## 4. Oban on the Lite engine

Still in `config/config.exs`, configure Oban to use the SQLite (`Lite`) engine
and your repo, with a `:claude` queue:

```elixir
config :my_app, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  repo: MyApp.Repo,
  queues: [claude: 2]
```

## 5. Start the repo and Oban

Add both to the supervision tree in `lib/my_app/application.ex` (the repo first,
so Oban has a database when it starts):

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, Application.fetch_env!(:my_app, Oban)}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

## 6. Create and migrate the database

Add an Oban migration at `priv/repo/migrations/20240101000000_add_oban.exs`:

```elixir
defmodule MyApp.Repo.Migrations.AddOban do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
```

```bash
mix ecto.create
mix ecto.migrate
```

## 7. Your first worker

A worker is a task definition. `use ObanClaude.Worker` injects a `perform/1`
that runs claude and maps the result onto an Oban return; you override
`handle_result/2`. Create `lib/my_app/summary_worker.ex`:

```elixir
defmodule MyApp.SummaryWorker do
  use ObanClaude.Worker,
    queue: :claude,
    max_attempts: 3,
    # A stubbed claude call so this first run works offline, with no API cost.
    # Delete the `query_fun` line to call the real `claude` CLI.
    query_fun: &__MODULE__.fake_query/2

  require Logger

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    Logger.info("claude said: #{inspect(result.result)} (cost $#{result.cost_usd || 0.0})")
    :ok
  end

  @doc false
  # A stubbed claude return, built with ObanClaude.Testing so the test/demo
  # never hard-codes claude_wrapper's struct shape.
  def fake_query(prompt, _opts) do
    {:ok, ObanClaude.Testing.result("a summary of: #{prompt}")}
  end
end
```

## 8. Enqueue a job and watch it run

```bash
iex -S mix
```

```elixir
%{"prompt" => "the oban_claude README"}
|> MyApp.SummaryWorker.new()
|> Oban.insert()
```

Within a moment the `:claude` queue picks the job up, runs the (stubbed) worker,
and `handle_result/2` logs:

```
[info] claude said: "a summary of: the oban_claude README" (cost $0.0)
```

That is the whole path: `Oban.insert/1` → the queue claims the job →
`perform/1` runs `ObanClaude.run/2` → the classifier maps the result →
`handle_result/2`. Oban owns the durability (retries, uniqueness, the reaper);
oban_claude is the seam that runs claude.

## 9. Test it offline

The `query_fun` seam is also the testing story: pass a stub `query_fun` and no
real claude call happens. [`ObanClaude.Testing`](ObanClaude.Testing.html) builds
the stub return values, so your tests never hard-code `claude_wrapper`'s structs
(and a shift in that representation breaks *this* library's tests, not yours).

`handle_result/2` is a plain function -- test it directly with a built result:

```elixir
defmodule MyApp.SummaryWorkerTest do
  use ExUnit.Case, async: true
  import ObanClaude.Testing

  test "handle_result/2 returns :ok on a clean result" do
    assert :ok = MyApp.SummaryWorker.handle_result(result("a summary"), %Oban.Job{args: %{}})
  end
end
```

To exercise the whole seam -- args → `run/2` → classifier -- pass a stub
`query_fun` to `ObanClaude.run/2`:

```elixir
# a clean success
assert {:ok, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: respond("done"))

# a failure, mapped by the default classifier
assert {{:cancel, :auth}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: fail(:auth))

# a retry path: attempt 1 is rate-limited, attempt 2 succeeds
qf = sequence([error(:auth, reason: :rate_limit), "done"])
assert {{:error, :rate_limit}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
assert {:ok, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
```

And `Oban.Testing.perform_job/3` runs the full worker (with its compiled-in stub
`query_fun`) when you want to assert the Oban return end-to-end:

```elixir
use Oban.Testing, repo: MyApp.Repo
assert :ok = perform_job(MyApp.SummaryWorker, %{"prompt" => "x"})
```

## 10. Make it real

Delete the `query_fun:` line from the worker. Now `perform/1` calls the real
`claude` CLI (via `claude_wrapper`), so you need `claude` installed and
authenticated. Build args with the [`ObanClaude.Args`](ObanClaude.Args.html)
builder instead of a raw map, and give it something to do:

```elixir
ObanClaude.Args.new(prompt: "Summarize the mix.exs in this project.",
                    working_dir: ".",
                    permission_mode: :plan)
|> MyApp.SummaryWorker.new()
|> Oban.insert()
```

Two things change once the calls are real (and paid):

- **`max_attempts`.** This guide kept the worker at `max_attempts: 3`, but a
  retry is a *fresh paid run* -- worst-case spend is `max_attempts ×
  max_budget_usd`. Lower it (a mutating worker should use `max_attempts: 1`)
  unless a re-run can genuinely change the outcome.
- **`timeout`.** Set an args-level `timeout` (e.g. `timeout: :timer.minutes(10)`)
  so a wedged CLI cannot block the queue indefinitely.

The [Agent worker patterns](agent_worker_patterns.html) guide has the full
fleet-safety checklist (process lifecycle, deploys, untrusted input).

## Where to next

- [Workers as task definitions](readme.html#workers-as-task-definitions) -- how
  worker `:args` defaults merge with per-job args.
- [Triggering](readme.html#triggering) -- run on a schedule (`Cron`) or from an
  event (insert + `unique`).
- [Isolation](readme.html#isolation-git-worktrees) and
  [Full-auto workers](readme.html#full-auto-workers) -- let a worker write to a
  repo and open PRs, safely.
- [Agent worker patterns](agent_worker_patterns.html) -- the review/merge and
  plan → implement → merge pipeline recipes.
