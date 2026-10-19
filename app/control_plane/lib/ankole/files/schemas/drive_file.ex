defmodule Ankole.Files.Schemas.DriveFile do
  @moduledoc """
  One file in an Agent or Pod drive: a path that names one byte content.

  The path is the identity that the model, the Console, and the adapters use.
  `size` is loaded from the referenced `files` row; it is not stored twice.
  """

  use Ankole.Schema, tenancy: :tenant

  alias Ankole.Files.Schemas.Blob
  alias Ankole.Principals.Principal

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @sources ~w(inbound generated sent agent console pod)

  @type t :: %__MODULE__{}

  schema "drive_files" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :path, :string

    belongs_to :blob, Blob, foreign_key: :sha256, references: :sha256, type: :binary
    field :size, :integer, virtual: true
    field :mode, :integer, default: 0o644
    field :content_type, :string
    field :source, :string
    field :conversation_id, Ecto.UUID
    field :message_id, Ecto.UUID

    timestamps()
  end

  @doc "Sources that may create a drive file."
  @spec sources() :: [String.t()]
  def sources, do: @sources
end
