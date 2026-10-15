defmodule Ankole.Sessions.AmbientJudgment do
  @moduledoc """
  Durable record of one ambient recognizer decision.

  One row per `im.message.may_intervene` Signal. A worker retry for the
  same event returns this canonical row, so retries cannot select a different
  route or HANDOFF target. `judged_until` records this Agent's progress in the
  shared conversation; `asked_by_state` records whether a proposed
  attribution passed worker validation (`accepted`) or failed it (`degraded`).
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Signals.Signal

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @actions ~w(NOOP FOREGROUND_REPLY NEW_WORK HANDOFF)
  @authorities ~w(NONE EXPLICIT_REQUEST STANDING_ORDER)
  @asked_by_states ~w(accepted degraded)

  @type t :: %__MODULE__{}

  schema "session_ambient_judgments" do
    belongs_to :signal, Signal, type: Ankole.Ecto.UUIDv7, primary_key: true

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :conversation_id, Ecto.UUID
    field :action, :string
    field :authority, :string
    field :handoff_job_id, :integer
    field :reason, :string, default: ""
    field :asked_by_message_id, Ecto.UUID
    field :asked_by_state, :string
    field :judged_until, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Builds a changeset for ambient judgment rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(judgment, attrs) do
    judgment
    |> cast(attrs, [
      :signal_id,
      :agent_uid,
      :conversation_id,
      :action,
      :authority,
      :handoff_job_id,
      :reason,
      :asked_by_message_id,
      :asked_by_state,
      :judged_until
    ])
    |> normalize_blank([:asked_by_message_id, :asked_by_state])
    |> update_change(:reason, &String.slice(&1 || "", 0, 2_000))
    |> validate_required([:signal_id, :agent_uid, :conversation_id, :action, :authority])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:authority, @authorities)
    |> validate_number(:handoff_job_id, greater_than: 0)
    |> validate_action_contract()
    |> validate_inclusion(:asked_by_state, @asked_by_states, allow_nil: true)
    |> foreign_key_constraint(:signal_id)
    |> foreign_key_constraint(:agent_uid)
    |> check_constraint(:asked_by_state,
      name: :session_ambient_judgments_asked_by_state_check
    )
    |> check_constraint(:action,
      name: :session_ambient_judgments_action_contract_check
    )
  end

  defp validate_action_contract(changeset) do
    action = get_field(changeset, :action)
    authority = get_field(changeset, :authority)
    handoff_job_id = get_field(changeset, :handoff_job_id)

    cond do
      action != "NEW_WORK" and authority != "NONE" ->
        add_error(changeset, :authority, "must be NONE unless action is NEW_WORK")

      action == "HANDOFF" and is_nil(handoff_job_id) ->
        add_error(changeset, :handoff_job_id, "is required for HANDOFF")

      action != "HANDOFF" and not is_nil(handoff_job_id) ->
        add_error(changeset, :handoff_job_id, "is only valid for HANDOFF")

      true ->
        changeset
    end
  end
end
