defmodule Ankole.BackgroundAgentJobs.Schemas.TurnItem do
  @moduledoc """
  One append-only sanitized semantic thread item of a BackgroundAgentJob Turn.

  This stream is the one turn content record from the Worker. The trajectory
  group projection is derived from it at write time, and thread replay reads
  it back when a lost Codex thread must be rebuilt.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "background_agent_job_turn_items" do
    belongs_to(:turn, Turn, type: Ecto.UUID, primary_key: true)
    field(:position, :integer, primary_key: true)
    field(:revision, :integer)
    field(:item_key, :string)
    field(:item, :map)
    timestamps(updated_at: false)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(turn_item, attrs) do
    turn_item
    |> cast(attrs, [:turn_id, :position, :revision, :item_key, :item, :inserted_at])
    |> normalize_blank([:item_key])
    |> validate_required([:turn_id, :position, :revision, :item_key, :item])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> JSONPayload.validate_map(:item, allow_datetime: true)
    |> validate_change(:item, fn :item, item ->
      if is_map(item) and is_binary(item["type"]) and item["type"] != "",
        do: [],
        else: [item: "must be one semantic thread item with a type"]
    end)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :position],
      name: :background_agent_job_turn_items_pkey
    )
    |> unique_constraint([:turn_id, :item_key],
      name: :background_agent_job_turn_items_item_key_index
    )
    |> check_constraint(:position, name: :baj_turn_items_position_nonnegative)
    |> check_constraint(:revision, name: :baj_turn_items_revision_nonnegative)
    |> check_constraint(:item_key, name: :baj_turn_items_item_key_present)
    |> check_constraint(:item, name: :baj_turn_items_item_check)
  end
end
