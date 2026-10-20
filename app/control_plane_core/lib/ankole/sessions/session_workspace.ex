defmodule Ankole.Sessions.SessionWorkspace do
  @moduledoc """
  Stable Agent Home workspace identity for one Session.

  The Session key remains `{agent_uid, session_id}`. The numeric primary key is
  only the model-visible directory name under the Agent's `sessions` tree.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]
  import Ecto.Changeset

  alias Ankole.Principals.Principal

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "sessions" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    field :conversation_id, Ankole.Ecto.UUIDv7
    field :epoch, :integer, default: 0

    timestamps()
  end

  @doc """
  Builds a changeset for a Session workspace.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:agent_uid, :session_id, :conversation_id])
    |> normalize_blank([:agent_uid, :session_id])
    |> validate_required([:agent_uid, :session_id])
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:agent_uid, :session_id],
      name: :sessions_session_index
    )
    |> check_constraint(:id, name: :sessions_id_range)
    |> check_constraint(:session_id, name: :sessions_session_id_present)
  end
end
