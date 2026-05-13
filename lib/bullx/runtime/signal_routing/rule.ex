defmodule BullX.Runtime.SignalRouting.Rule do
  @moduledoc """
  Persisted operator-managed rule for Runtime Signal routing.

  Rules are fixed-column data. They choose an Agent Principal destination or
  the explicit blackhole sink; they do not store executable predicates,
  provider payload paths, LLM configuration, prompts, or route-owned runtime
  target data.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @route_actions [:deliver_agent, :drop_signal]
  @sink_kinds [:blackhole]
  @match_fields [
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :actor_external_id,
    :actor_bot,
    :event_type,
    :event_name,
    :routing_fact_key
  ]
  @string_fields [
    :key,
    :name,
    :description,
    :signal_type,
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :actor_external_id,
    :event_type,
    :event_name,
    :routing_fact_key,
    :routing_fact_value,
    :reason
  ]

  @type t :: %__MODULE__{}

  schema "signal_route_rules" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :signal_type, :string
    field :adapter, :string
    field :channel_id, :string
    field :scope_id, :string
    field :thread_id, :string
    field :actor_external_id, :string
    field :actor_bot, :boolean
    field :event_type, :string
    field :event_name, :string
    field :routing_fact_key, :string
    field :routing_fact_value, :string
    field :route_action, Ecto.Enum, values: @route_actions
    field :sink_kind, Ecto.Enum, values: @sink_kinds
    field :reason, :string
    field :metadata, :map, default: %{}

    belongs_to :agent, Agent,
      foreign_key: :agent_principal_id,
      references: :principal_id,
      define_field: false

    field :agent_principal_id, :binary_id

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) when is_map(attrs) do
    rule
    |> cast(attrs, [
      :key,
      :name,
      :description,
      :enabled,
      :priority,
      :signal_type,
      :adapter,
      :channel_id,
      :scope_id,
      :thread_id,
      :actor_external_id,
      :actor_bot,
      :event_type,
      :event_name,
      :routing_fact_key,
      :routing_fact_value,
      :route_action,
      :agent_principal_id,
      :sink_kind,
      :reason,
      :metadata
    ])
    |> normalize_blank(@string_fields)
    |> normalize_key()
    |> validate_required([:key, :name, :enabled, :priority, :signal_type, :route_action, :reason])
    |> validate_format(:key, ~r/\A[a-z][a-z0-9_-]{0,62}\z/)
    |> validate_format(:routing_fact_key, ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/)
    |> validate_format(:reason, ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_map(:metadata)
    |> validate_routing_fact_pair()
    |> validate_target_combination()
    |> validate_broad_match_shape()
    |> unique_constraint(:key)
    |> foreign_key_constraint(:agent_principal_id)
    |> check_constraint(:key, name: :signal_route_rules_key_format)
    |> check_constraint(:priority, name: :signal_route_rules_priority_range)
    |> check_constraint(:signal_type, name: :signal_route_rules_signal_type_required)
    |> check_constraint(:routing_fact_key, name: :signal_route_rules_routing_fact_pair)
    |> check_constraint(:routing_fact_key, name: :signal_route_rules_routing_fact_key_format)
    |> check_constraint(:metadata, name: :signal_route_rules_metadata_object)
    |> check_constraint(:reason, name: :signal_route_rules_reason_format)
    |> check_constraint(:route_action, name: :signal_route_rules_target_combination)
    |> check_constraint(:signal_type, name: :signal_route_rules_non_broad_match)
  end

  @spec destination_key(t()) :: String.t()
  def destination_key(%__MODULE__{route_action: :deliver_agent, agent_principal_id: id}),
    do: "agent:#{id}"

  def destination_key(%__MODULE__{route_action: :drop_signal, sink_kind: :blackhole}),
    do: "sink:blackhole"

  @spec route_action_string(t()) :: String.t()
  def route_action_string(%__MODULE__{route_action: action}), do: Atom.to_string(action)

  @spec sink_kind_string(t()) :: String.t() | nil
  def sink_kind_string(%__MODULE__{sink_kind: nil}), do: nil
  def sink_kind_string(%__MODULE__{sink_kind: kind}), do: Atom.to_string(kind)

  defp normalize_key(changeset) do
    update_change(changeset, :key, &String.downcase/1)
  end

  defp validate_routing_fact_pair(changeset) do
    case {get_field(changeset, :routing_fact_key), get_field(changeset, :routing_fact_value)} do
      {nil, nil} -> changeset
      {key, value} when is_binary(key) and is_binary(value) -> changeset
      _other -> add_error(changeset, :routing_fact_key, "must be set with routing_fact_value")
    end
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

  defp validate_broad_match_shape(changeset) do
    case has_non_signal_match?(changeset) do
      true -> changeset
      false -> validate_broad_inbound_agent_route(changeset)
    end
  end

  defp has_non_signal_match?(changeset) do
    Enum.any?(@match_fields, fn field -> not is_nil(get_field(changeset, field)) end)
  end

  defp validate_broad_inbound_agent_route(changeset) do
    case {get_field(changeset, :signal_type), get_field(changeset, :route_action)} do
      {"com.agentbull.x.inbound.received", :deliver_agent} ->
        changeset

      _other ->
        add_error(changeset, :signal_type, "requires a non-signal match column")
    end
  end
end
