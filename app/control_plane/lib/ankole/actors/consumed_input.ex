defmodule Ankole.Actors.ConsumedInput do
  @moduledoc """
  Actor-store marker that a mailbox input reached durable actor state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "actor_consumed_inputs" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :binding_name, :string, primary_key: true
    field :ingress_event_id, :string, primary_key: true
    field :session_id, :string
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :provider_entry_id, :string
    field :type, :string
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(input, attrs) do
    input
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :ingress_event_id,
      :session_id,
      :signal_channel_id,
      :provider_thread_id,
      :provider_entry_id,
      :type,
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
      :type
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :binding_name,
      :ingress_event_id,
      :session_id,
      :type,
      :consumed_at
    ])
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :ingress_event_id],
      name: :actor_consumed_inputs_pkey
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
