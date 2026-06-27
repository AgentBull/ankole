defmodule Ankole.SignalsGateway.InboundBatch do
  @moduledoc """
  Short-lived IM ingress grouping state before ActorInput creation.

  A row here is not actor work yet. It holds provider messages for one
  agent/binding/channel/thread until SignalsGateway can decide whether they
  close as addressed input, ambient observation, or no actor input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.Types.JsonValue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open finalized canceled)
  @modes ~w(neutral addressed)
  @policies ~w(ignore record_only may_intervene)
  @outcomes ~w(addressed ambient no_actor_input canceled)

  schema "signal_gateway_inbound_batches" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :binding_name, :string
    field :session_id, :string

    belongs_to :channel, SignalChannel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string

    field :provider_thread_id, :string, default: ""
    field :batch_state, :string, default: "open"
    field :mode, :string, default: "neutral"
    field :policy, :string
    field :requester_sender_key, :string
    field :entries, JsonValue, default: []
    field :available_at, :utc_datetime_usec
    field :hard_cap_at, :utc_datetime_usec
    field :batch_revision, :integer, default: 0
    field :outcome, :string
    field :finalized_at, :utc_datetime_usec
    field :actor_input_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :batch_state,
      :mode,
      :policy,
      :requester_sender_key,
      :entries,
      :available_at,
      :hard_cap_at,
      :batch_revision,
      :outcome,
      :finalized_at,
      :actor_input_id
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :batch_state,
      :mode,
      :policy,
      :requester_sender_key,
      :outcome
    ])
    |> normalize_uid(:agent_uid)
    |> normalize_thread_key()
    |> validate_required([
      :agent_uid,
      :binding_name,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :batch_state,
      :mode,
      :policy,
      :entries,
      :available_at,
      :batch_revision
    ])
    |> validate_inclusion(:batch_state, @states)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:policy, @policies)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:batch_revision, greater_than_or_equal_to: 0)
    |> validate_entries()
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:signal_channel_id)
    |> unique_constraint([:agent_uid, :binding_name, :signal_channel_id, :provider_thread_id],
      name: :signal_gateway_inbound_batches_open_index
    )
    |> check_constraint(:entries, name: :inbound_batches_entries_array)
    |> check_constraint(:batch_state, name: :inbound_batches_state_check)
    |> check_constraint(:mode, name: :inbound_batches_mode_check)
    |> check_constraint(:policy, name: :inbound_batches_policy_check)
    |> check_constraint(:outcome, name: :inbound_batches_outcome_check)
  end

  defp validate_entries(changeset) do
    validate_change(changeset, :entries, fn
      :entries, entries when is_list(entries) -> []
      :entries, _value -> [entries: "must be a JSON array"]
    end)
  end

  defp normalize_thread_key(changeset) do
    update_change(changeset, :provider_thread_id, fn
      nil -> ""
      value -> value
    end)
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
