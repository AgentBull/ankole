defmodule Ankole.Memory.Episode do
  @moduledoc """
  Channel-level Layer B historical memory episode.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.SignalsGateway.Channel
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @embedding_states ~w(pending synced failed)

  schema "memory_episodes" do
    belongs_to :channel, Channel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string

    field :topic, :string
    field :summary, :string
    field :source_entry_ids, {:array, :string}, default: []
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :embedding, :string
    field :embedding_dimensions, :integer
    field :embedding_state, :string, default: "pending"
    field :embedding_error, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :signal_channel_id,
      :topic,
      :summary,
      :source_entry_ids,
      :started_at,
      :ended_at,
      :embedding,
      :embedding_dimensions,
      :embedding_state,
      :embedding_error,
      :metadata
    ])
    |> normalize_blank([:signal_channel_id, :topic, :summary, :embedding_error])
    |> validate_required([
      :signal_channel_id,
      :topic,
      :summary,
      :source_entry_ids,
      :started_at,
      :ended_at,
      :embedding_state,
      :metadata
    ])
    |> validate_inclusion(:embedding_state, @embedding_states)
    |> validate_number(:embedding_dimensions, greater_than: 0)
    |> foreign_key_constraint(:signal_channel_id)
    |> check_constraint(:topic, name: :memory_episodes_topic_present)
    |> check_constraint(:summary, name: :memory_episodes_summary_present)
    |> check_constraint(:embedding_state, name: :memory_episodes_embedding_state_check)
    |> check_constraint(:embedding_dimensions,
      name: :memory_episodes_embedding_dimensions_positive
    )
    |> JsonPayload.validate_map(:metadata)
    |> check_constraint(:metadata, name: :memory_episodes_metadata_object)
  end
end
