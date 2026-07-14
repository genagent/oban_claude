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

  # Encodes the prompt and query opts run/2 produced into the result, so a test
  # can inspect what the worker merged and passed through.
  def echo(prompt, opts),
    do: {:ok, %Result{result: inspect({prompt, Enum.sort(opts)}), is_error: false}}

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

  defmodule MergeWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.echo/2,
      args: %{"model" => "haiku", "system_prompt" => "fixed"}

    @impl ObanClaude.Worker
    def handle_result(result, _job), do: {:ok, result.result}
  end

  defmodule RoutineWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.echo/2,
      args: %{"prompt" => "standing task", "model" => "haiku"}

    @impl ObanClaude.Worker
    def handle_result(result, _job), do: {:ok, result.result}
  end

  defmodule DefaultsWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.echo/2,
      args: ObanClaude.Args.defaults(model: "haiku", system_prompt: "fixed")

    @impl ObanClaude.Worker
    def handle_result(result, _job), do: {:ok, result.result}
  end

  defmodule ClassifierWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.query_ok/2,
      classifier: &__MODULE__.classify/1

    # A worker-level classifier, returning the required {oban_return, payload}
    # envelope. Defers everything but the overridden case to the default mapping.
    def classify({:ok, %Result{} = r}), do: {{:cancel, :always}, r}
    def classify(outcome), do: ObanClaude.Outcome.classify(outcome)
  end

  defmodule FlatClassifierWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.query_ok/2,
      classifier: &__MODULE__.classify/1

    # The classic mistake: a flat verdict instead of the envelope. run/2 must
    # reject it rather than let Oban record the failed job as success.
    def classify(_outcome), do: {:cancel, :always}
  end

  defmodule PerformOverrideWorker do
    use ObanClaude.Worker, queue: :test

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: {:cancel, :overridden}
  end

  defmodule PinnedWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.echo/2,
      args: %{"model" => "haiku"},
      pinned_args: %{"permission_mode" => "plan"}

    @impl ObanClaude.Worker
    def handle_result(result, _job), do: {:ok, result.result}
  end

  defmodule SnoozeWorker do
    use ObanClaude.Worker,
      queue: :test,
      query_fun: &ObanClaude.WorkerTest.query_ok/2,
      classifier: &__MODULE__.classify/1

    # A classifier that opts into snooze (the default mapping never does).
    def classify({:ok, %Result{} = r}), do: {{:snooze, 30}, r}
    def classify(outcome), do: ObanClaude.Outcome.classify(outcome)
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

  test "worker :args defaults merge under job args (job wins on conflicts)" do
    {:ok, captured} = MergeWorker.perform(job(%{"prompt" => "hi", "model" => "sonnet"}))

    assert captured =~ ~s("hi")
    assert captured =~ ~s(model: "sonnet")
    assert captured =~ ~s(system_prompt: "fixed")
  end

  test "a fully preconfigured worker runs its task from an empty job (routine)" do
    {:ok, captured} = RoutineWorker.perform(job(%{}))

    assert captured =~ ~s("standing task")
    assert captured =~ ~s(model: "haiku")
  end

  test "worker :args built with Args.defaults/1 evaluates at compile time and merges" do
    {:ok, captured} = DefaultsWorker.perform(job(%{"prompt" => "hi"}))

    assert captured =~ ~s("hi")
    assert captured =~ ~s(model: "haiku")
    assert captured =~ ~s(system_prompt: "fixed")
  end

  test "a worker-level :classifier's verdict flows through perform/1 (nested envelope)" do
    assert {:cancel, :always} = ClassifierWorker.perform(job(%{"prompt" => "x"}))
  end

  test "a worker whose classifier returns a flat verdict cancels with :invalid_args" do
    assert {:cancel, {:invalid_args, message}} =
             FlatClassifierWorker.perform(job(%{"prompt" => "x"}))

    assert message =~ "envelope"
  end

  test "perform/1 is overridable" do
    assert {:cancel, :overridden} = PerformOverrideWorker.perform(job(%{"prompt" => "x"}))
  end

  test "a {:snooze, n} verdict passes through perform/1 to Oban" do
    assert {:snooze, 30} = SnoozeWorker.perform(job(%{"prompt" => "x"}))
  end

  test "pinned_args win over job args, while non-pinned defaults still yield to the job" do
    {:ok, captured} =
      PinnedWorker.perform(
        job(%{"prompt" => "x", "permission_mode" => "bypass_permissions", "model" => "sonnet"})
      )

    # pinned key: the worker wins even though the job supplied it
    assert captured =~ "permission_mode: :plan"
    # non-pinned default: the job still wins
    assert captured =~ ~s(model: "sonnet")
  end

  describe "args validation at the seam (#75)" do
    test "a missing prompt cancels as :invalid_args instead of raising (no retry storm)" do
      assert {:cancel, {:invalid_args, message}} = DefaultWorker.perform(job(%{}))
      assert message =~ "prompt"
    end

    test "an unknown permission_mode cancels as :invalid_args" do
      assert {:cancel, {:invalid_args, message}} =
               DefaultWorker.perform(
                 job(%{"prompt" => "x", "permission_mode" => "bypassPermissions"})
               )

      assert message =~ "permission_mode"
    end

    test "the :invalid_args message omits the args map (no prompt/meta leak)" do
      assert {:cancel, {:invalid_args, message}} =
               DefaultWorker.perform(
                 job(%{"system_prompt" => "secret-ish", "meta_token" => "abc"})
               )

      refute message =~ "secret-ish"
      refute message =~ "abc"
    end

    test "__validate_arg_keys__! rejects non-binary keys and accepts string keys" do
      assert_raise ArgumentError, ~r/keys must be strings/, fn ->
        ObanClaude.Worker.__validate_arg_keys__!(__MODULE__, :args, %{model: "haiku"})
      end

      assert :ok =
               ObanClaude.Worker.__validate_arg_keys__!(__MODULE__, :args, %{"model" => "haiku"})

      assert :ok = ObanClaude.Worker.__validate_arg_keys__!(__MODULE__, :pinned_args, %{})
    end
  end
end
