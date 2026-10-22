defmodule Ankole.Sessions.RoundState do
  @moduledoc "Session progress committed with its model request or tool journal."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Sessions.Domain
  require Ash.Query
  alias Ankole.Sessions.Outcome
  alias Ankole.Sessions.ToolResult

  @control_fields [:iteration, :nudged, :repaired, :repair_failure, :truncated_rounds, :outcome]

  postgres do
    table("session_round_states")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:message_id, "session_round_states_message_id_fkey"}])

    check_constraints do
      check_constraint(:outcome, "session_round_states_outcome")
      check_constraint(:pages, "session_round_states_pages_object")
      check_constraint(:results, "session_round_states_results_object")
    end
  end

  attributes do
    attribute(:message_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:iteration, :integer, default: 0, allow_nil?: false)
    attribute(:steer_event_ids, {:array, Ankole.Ash.Types.UUIDv7}, default: [], allow_nil?: false)
    attribute(:nudged, :boolean, default: false, allow_nil?: false)
    attribute(:repaired, :boolean, default: false, allow_nil?: false)
    attribute(:repair_failure, :string, constraints: [trim?: false])
    attribute(:workflow_attempt, :integer)
    attribute(:truncated_rounds, :integer, default: 0, allow_nil?: false)

    attribute(:outcome, :atom,
      constraints: [one_of: Outcome.values()],
      default: :loop_finished,
      allow_nil?: false
    )

    attribute(:pages, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false)
    attribute(:results, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create_if_absent :record_once, upsert_fields: [:message_id] do
      primary?(true)
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :message_id,
        :iteration,
        :steer_event_ids,
        :nudged,
        :repaired,
        :repair_failure,
        :workflow_attempt,
        :truncated_rounds,
        :outcome,
        :pages,
        :results
      ])
    end
  end

  def put_in_tx(_repo, run, message, results \\ %{}) do
    attrs =
      Map.take(run, @control_fields ++ [:steer_event_ids, :pages])
      |> Map.put(
        :workflow_attempt,
        if(run.kind == :workflow_task, do: run.spec.request_context["attempt"])
      )
      |> Map.put(:message_id, message.id)
      |> Map.put(
        :results,
        Map.new(results, fn {id, result} -> {id, ToolResult.journal_fields(result)} end)
      )

    with {:ok, _} <- Ankole.Ash.create(__MODULE__, :record_once, attrs),
         do: :ok
  end

  def restore(run, %{__struct__: __MODULE__} = state),
    do: struct!(run, Map.take(state, @control_fields))

  def get(nil), do: struct(__MODULE__)

  def get(message) do
    __MODULE__
    |> Ash.Query.filter(message_id == ^message.id)
    |> Ankole.Ash.read_one!()
    |> then(&(&1 || struct(__MODULE__)))
  end

  def load(rows) do
    ids = Enum.map(rows, & &1.id)

    __MODULE__
    |> Ash.Query.filter(message_id in ^ids)
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.message_id, &1})
  end

  def for_message(_states, nil), do: struct(__MODULE__)

  def for_message(states, message),
    do: Map.get_lazy(states, message.id, fn -> struct(__MODULE__) end)
end
