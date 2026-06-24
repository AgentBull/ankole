defmodule Ankole.Actors.ActorInputConsumption do
  @moduledoc """
  Recovery-window marker that an actor input reached durable actor state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "actor_input_consumptions" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :actor_input_id, Ecto.UUID
    field :binding_name, :string
    field :ingress_event_id, :string
    field :session_id, :string
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :provider_entry_id, :string
    field :type, :string
    field :conversation_id, Ecto.UUID
    field :user_message_id, Ecto.UUID
    field :llm_turn_id, Ecto.UUID
    field :activation_uid, :string
    field :actor_epoch, :integer
    field :revision, :integer
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(input, attrs) do
    input
    |> cast(attrs, [
      :actor_input_id,
      :agent_uid,
      :binding_name,
      :ingress_event_id,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :provider_entry_id,
      :type,
      :conversation_id,
      :user_message_id,
      :llm_turn_id,
      :activation_uid,
      :actor_epoch,
      :revision,
      :consumed_at
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :ingress_event_id,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :provider_entry_id,
      :type,
      :activation_uid
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :actor_input_id,
      :agent_uid,
      :binding_name,
      :ingress_event_id,
      :session_id,
      :type,
      :llm_turn_id,
      :activation_uid,
      :actor_epoch,
      :revision,
      :consumed_at
    ])
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:actor_input_id], name: :actor_input_consumptions_actor_input_id_index)
    |> unique_constraint([:agent_uid, :binding_name, :ingress_event_id],
      name: :actor_input_consumptions_signal_idempotency_index
    )
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
