defmodule Ankole.SignalsGateway.InputTombstone do
  @moduledoc """
  Short-lived guard that prevents late receive redelivery after delete or recall.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.SignalChannel

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_gateway_input_tombstones" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :binding_name, :string, primary_key: true

    belongs_to :channel, SignalChannel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string,
      primary_key: true

    field :provider_entry_id, :string, primary_key: true
    field :tombstoned_until, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :signal_channel_id,
      :provider_entry_id,
      :tombstoned_until
    ])
    |> normalize_blank([:agent_uid, :binding_name, :signal_channel_id, :provider_entry_id])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :binding_name,
      :signal_channel_id,
      :provider_entry_id,
      :tombstoned_until
    ])
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:signal_channel_id)
    |> unique_constraint(
      [:agent_uid, :binding_name, :signal_channel_id, :provider_entry_id],
      name: :signal_gateway_input_tombstones_pkey
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
