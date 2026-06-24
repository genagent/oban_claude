defmodule ObanClaude.WorkerTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Error, Result}

  # Stub claude entrypoints, injected through the worker's :query_fun seam so
  # perform/1 runs the real ObanClaude.run/2 path without calling claude.
  def query_ok(_prompt, _opts), do: {:ok, %Result{result: "done", is_error: false}}

  def query_blocked(_prompt, _opts) do
    {:ok,
     %Result{
       result: "",
       is_error: false,
       extra: %{"structured_output" => %{"outcome" => "blocked"}}
     }}
  end

  def query_auth(_prompt, _opts), do: {:error, %Error{kind: :auth}}

  defmodule DefaultWorker do
    use ObanClaude.Worker, queue: :test, query_fun: &ObanClaude.WorkerTest.query_ok/2
  end

  defmodule BlockingWorker do
    use ObanClaude.Worker, queue: :test, query_fun: &ObanClaude.WorkerTest.query_blocked/2

    @impl ObanClaude.Worker
    def handle_result(result, _job) do
      case ObanClaude.outcome(result) do
        "blocked" -> {:cancel, :blocked}
        _ -> :ok
      end
    end
  end

  defmodule AuthWorker do
    use ObanClaude.Worker, queue: :test, query_fun: &ObanClaude.WorkerTest.query_auth/2
  end

  defp job(args), do: %Oban.Job{args: args}

  test "the default handle_result/2 returns :ok on a clean result" do
    assert :ok = DefaultWorker.perform(job(%{"prompt" => "x"}))
  end

  test "a handle_result/2 override can cancel on a structured outcome" do
    assert {:cancel, :blocked} = BlockingWorker.perform(job(%{"prompt" => "x"}))
  end

  test "a claude error passes the classifier verdict straight through to Oban" do
    assert {:cancel, :auth} = AuthWorker.perform(job(%{"prompt" => "x"}))
  end
end
