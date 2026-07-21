defmodule ObanClaude.Agent.Supervisor do
  @moduledoc """
  The supervision root for the agent lifecycle spike: a `Registry` (tracking
  `agent_id -> current state`) plus a `DynamicSupervisor` that owns the
  `ObanClaude.Agent.Instance` processes.

  The library starts no daemon by itself; a host app opts in by adding this to
  its tree (after its Oban instance, so agents can enqueue):

      children = [
        MyApp.Repo,
        {Oban, Application.fetch_env!(:my_app, Oban)},
        ObanClaude.Agent.Supervisor
      ]

  The strategy is `:rest_for_one` with the registry first: instances register
  through the registry at startup, so it must always be up before (and outlive
  a restart of) the instance supervisor.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: ObanClaude.Agent.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: ObanClaude.Agent.InstanceSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
