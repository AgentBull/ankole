defmodule Ankole.Memory.Note do
  @moduledoc """
  Curated Layer A memory note for one agent in one signal channel.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "memory_notes" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    belongs_to :channel, Channel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string

    field :content, :string
    field :source, :map, default: %{}

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:agent_uid, :signal_channel_id, :content, :source])
    |> normalize_blank([:agent_uid, :signal_channel_id, :content])
    |> normalize_uid(:agent_uid)
    |> validate_required([:agent_uid, :signal_channel_id, :content, :source])
    |> validate_length(:content, max: 500)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:signal_channel_id)
    |> check_constraint(:content, name: :memory_notes_content_present)
    |> check_constraint(:content, name: :memory_notes_content_length)
    |> JsonPayload.validate_map(:source)
    |> check_constraint(:source, name: :memory_notes_source_object)
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
