defmodule Ankole.IdentityProviders.LocalPassword.RetryGuard.Supervisor do
  @moduledoc """
  Stops all password verification tasks before the attempt guard restarts.
  """

  use Supervisor

  alias Ankole.IdentityProviders.LocalPassword.RetryGuard

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, RetryGuard.TaskSupervisor)
    guard = Keyword.get(opts, :guard, RetryGuard)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_supervisor}, shutdown: :infinity),
      {RetryGuard,
       opts |> Keyword.put(:name, guard) |> Keyword.put(:task_supervisor, task_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
