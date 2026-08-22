defmodule Ankole.BackgroundAgentJobs.Schemas.TrajectoryGroup do
  @moduledoc """
  One append-only semantic item group in a BackgroundAgentJob Turn trajectory.

  New Turns store no group rows: `Ankole.BackgroundAgentJobs.Schemas.TurnItem`
  is the storage and read-path owner. Readers use these rows only for a Turn
  recorded before the item stream existed, so the rows stay until that
  history is retired.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Trajectory
  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "background_agent_job_turn_trajectory_groups" do
    belongs_to(:turn, Turn, type: Ecto.UUID, primary_key: true)
    field(:position, :integer, primary_key: true)
    field(:revision, :integer)
    field(:item_key, :string)
    field(:content, :map)
    timestamps(updated_at: false)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:turn_id, :position, :revision, :item_key, :content, :inserted_at])
    |> normalize_blank([:item_key])
    |> validate_required([:turn_id, :position, :revision, :item_key, :content])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> JSONPayload.validate_map(:content, allow_datetime: true)
    |> validate_change(:content, fn :content, content ->
      if Trajectory.valid_group_content?(content),
        do: [],
        else: [content: "must contain one or more canonical ChatML messages"]
    end)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :position],
      name: :background_agent_job_turn_trajectory_groups_pkey
    )
    |> unique_constraint([:turn_id, :item_key],
      name: :background_agent_job_turn_trajectory_groups_item_index
    )
    |> check_constraint(:position,
      name: :baj_turn_trajectory_groups_position_nonnegative
    )
    |> check_constraint(:revision,
      name: :baj_turn_trajectory_groups_revision_nonnegative
    )
    |> check_constraint(:item_key,
      name: :baj_turn_trajectory_groups_item_key_present
    )
    |> check_constraint(:content,
      name: :baj_turn_trajectory_groups_content_check
    )
  end
end
