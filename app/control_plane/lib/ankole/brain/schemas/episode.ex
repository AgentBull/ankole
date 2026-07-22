defmodule Ankole.Brain.Schemas.Episode do
  @moduledoc "A time-addressable summary index over immutable chat-layer facts."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.Channel

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_episodes" do
    belongs_to :channel, Channel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string

    field :topic, :string
    field :summary, :string
    field :source_entry_ids, {:array, :string}, default: []
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_dimensions, :integer
    field :embedding_model_agent_uid, :string
    field :embedding_state, Ecto.Enum, values: [:pending, :synced, :failed], default: :pending
    field :embedding_error, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
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
      :embedding_model_agent_uid,
      :embedding_state,
      :embedding_error,
      :metadata
    ])
    |> normalize_blank([
      :signal_channel_id,
      :topic,
      :summary,
      :embedding_model_agent_uid,
      :embedding_error
    ])
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
    |> validate_number(:embedding_dimensions, greater_than: 0)
    |> JSONPayload.validate_map(:metadata)
    |> foreign_key_constraint(:signal_channel_id)
    |> check_constraint(:topic, name: :brain_episodes_topic_present)
    |> check_constraint(:summary, name: :brain_episodes_summary_present)
    |> check_constraint(:embedding_dimensions,
      name: :brain_episodes_embedding_dimensions_positive
    )
    |> check_constraint(:embedding_state, name: :brain_episodes_embedding_state_consistent)
    |> check_constraint(:metadata, name: :brain_episodes_metadata_object)
  end
end
