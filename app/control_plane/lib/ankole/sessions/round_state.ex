defmodule Ankole.Sessions.RoundState do
  @moduledoc "Session progress committed with its model request or tool journal."
  use Ankole.Schema, tenancy: :tenant
  import Ecto.Query
  alias Ankole.Sessions.Outcome
  alias Ankole.Sessions.ToolResult
  alias Ankole.Repo

  @primary_key false
  schema "session_round_states" do
    field :message_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :iteration, :integer, default: 0
    field :steer_event_ids, {:array, Ankole.Ecto.UUIDv7}, default: []
    field :nudged, :boolean, default: false
    field :repaired, :boolean, default: false
    field :repair_failure, :string
    field :workflow_attempt, :integer
    field :truncated_rounds, :integer, default: 0
    field :outcome, Ecto.Enum, values: Outcome.values(), default: :loop_finished
    field :pages, :map, default: %{}
    field :results, :map, default: %{}
  end

  def put_in_tx(repo, run, message, results \\ %{}) do
    attrs =
      Map.take(run, [
        :iteration,
        :steer_event_ids,
        :nudged,
        :repaired,
        :repair_failure,
        :truncated_rounds,
        :outcome,
        :pages
      ])
      |> Map.put(
        :workflow_attempt,
        if(run.kind == :workflow_task, do: run.spec.request_context["attempt"])
      )
      |> Map.put(:message_id, message.id)
      |> Map.put(
        :results,
        Map.new(results, fn {id, result} -> {id, ToolResult.journal_fields(result)} end)
      )

    with {:ok, _} <-
           %__MODULE__{} |> Ecto.Changeset.change(attrs) |> repo.insert(on_conflict: :nothing),
         do: :ok
  end

  def get(nil), do: %__MODULE__{}
  def get(message), do: Repo.get(__MODULE__, message.id) || %__MODULE__{}

  def load(rows) do
    ids = Enum.map(rows, & &1.id)

    Repo.all(from s in __MODULE__, where: s.message_id in ^ids)
    |> Map.new(&{&1.message_id, &1})
  end

  def for_message(_states, nil), do: %__MODULE__{}
  def for_message(states, message), do: Map.get(states, message.id, %__MODULE__{})
end
