defmodule BullX.Runtime.SignalRouting.RouteDecision do
  @moduledoc """
  Durable routing outcome produced from a Gateway Mailbox delivery.

  A route decision records one resolved destination for one Signal publish. It
  is not authorization to perform external effects and it is not a Gateway
  Signal archive. Sink decisions keep only routing explanation; Agent decisions
  may additionally store the normalized content projection needed by later
  Agent ingress.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Agent
  alias BullX.Runtime.SignalRouting.Rule

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @route_actions [:deliver_agent, :drop_signal]
  @sink_kinds [:blackhole]

  @string_fields [
    :delivery_key,
    :signal_occurrence_key,
    :signal_type,
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :event_type,
    :event_name,
    :destination_key,
    :rule_key,
    :reason
  ]

  @type t :: %__MODULE__{}

  schema "signal_route_decisions" do
    field :delivery_key, :string
    field :signal_occurrence_key, :string
    field :signal_id, Ecto.UUID
    field :signal_type, :string
    field :signal_time, :utc_datetime_usec
    field :adapter, :string
    field :channel_id, :string
    field :scope_id, :string
    field :thread_id, :string
    field :event_type, :string
    field :event_name, :string
    field :actor_bot, :boolean
    field :external_actor, :map, default: %{}
    field :destination_key, :string
    field :route_action, Ecto.Enum, values: @route_actions
    field :sink_kind, Ecto.Enum, values: @sink_kinds
    field :rule_key, :string
    field :reason, :string
    field :routing_snapshot, :map
    field :content_snapshot, :map
    field :decision_metadata, :map, default: %{}

    belongs_to :agent, Agent,
      foreign_key: :agent_principal_id,
      references: :principal_id,
      define_field: false

    field :agent_principal_id, :binary_id

    belongs_to :rule, Rule, define_field: false
    field :rule_id, :binary_id

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(decision, attrs) when is_map(attrs) do
    decision
    |> cast(attrs, [
      :delivery_key,
      :signal_occurrence_key,
      :signal_id,
      :signal_type,
      :signal_time,
      :adapter,
      :channel_id,
      :scope_id,
      :thread_id,
      :event_type,
      :event_name,
      :actor_bot,
      :external_actor,
      :destination_key,
      :route_action,
      :agent_principal_id,
      :sink_kind,
      :rule_id,
      :rule_key,
      :reason,
      :routing_snapshot,
      :content_snapshot,
      :decision_metadata
    ])
    |> normalize_blank(@string_fields)
    |> validate_required([
      :delivery_key,
      :signal_occurrence_key,
      :signal_id,
      :signal_type,
      :signal_time,
      :external_actor,
      :destination_key,
      :route_action,
      :rule_key,
      :reason,
      :routing_snapshot,
      :decision_metadata
    ])
    |> validate_format(:destination_key, ~r/\A[a-z][a-z0-9_:-]{0,190}\z/)
    |> validate_format(:reason, ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/)
    |> validate_map(:external_actor)
    |> validate_map(:routing_snapshot)
    |> validate_map(:decision_metadata)
    |> validate_optional_map(:content_snapshot)
    |> validate_target_combination()
    |> validate_sink_content_boundary()
    |> unique_constraint([:signal_id, :destination_key])
    |> foreign_key_constraint(:agent_principal_id)
    |> foreign_key_constraint(:rule_id)
    |> check_constraint(:external_actor, name: :signal_route_decisions_external_actor_object)
    |> check_constraint(:routing_snapshot, name: :signal_route_decisions_routing_snapshot_object)
    |> check_constraint(:content_snapshot, name: :signal_route_decisions_content_snapshot_object)
    |> check_constraint(:decision_metadata, name: :signal_route_decisions_metadata_object)
    |> check_constraint(:destination_key, name: :signal_route_decisions_destination_key_format)
    |> check_constraint(:reason, name: :signal_route_decisions_reason_format)
    |> check_constraint(:route_action, name: :signal_route_decisions_target_combination)
    |> check_constraint(:content_snapshot, name: :signal_route_decisions_sink_has_no_content)
  end

  defp validate_optional_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_nil(value) or is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end

  defp validate_target_combination(changeset) do
    case {
      get_field(changeset, :route_action),
      get_field(changeset, :agent_principal_id),
      get_field(changeset, :sink_kind)
    } do
      {:deliver_agent, agent_id, nil} when is_binary(agent_id) ->
        changeset

      {:drop_signal, nil, :blackhole} ->
        changeset

      _other ->
        add_error(changeset, :route_action, "has invalid destination combination")
    end
  end

  defp validate_sink_content_boundary(changeset) do
    case {get_field(changeset, :route_action), get_field(changeset, :content_snapshot)} do
      {:drop_signal, nil} ->
        changeset

      {:drop_signal, _content} ->
        add_error(changeset, :content_snapshot, "must be empty for sinks")

      _other ->
        changeset
    end
  end
end
