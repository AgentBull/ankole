defmodule Ankole.Files.Schemas.AgentFile do
  @moduledoc """
  One file in an Agent's drive: a path that names one byte content.

  The path is the identity that the model, the Console, and the adapters use.
  `size` is loaded from the referenced `files` row; it is not stored twice.
  """

  use Ankole.Schema, tenancy: :tenant

  alias Ankole.Files.Schemas.Blob
  alias Ankole.Principals.Principal

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @sources ~w(inbound generated sent agent console)

  @type t :: %__MODULE__{}

  schema "agent_files" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :path, :string, primary_key: true

    belongs_to :blob, Blob, foreign_key: :sha256, references: :sha256, type: :binary
    field :size, :integer, virtual: true
    field :mode, :integer, default: 0o644
    field :content_type, :string
    field :source, :string
    field :signal_channel_id, :string
    field :source_entry_id, :string

    timestamps()
  end

  @doc "Sources that may create a drive file."
  @spec sources() :: [String.t()]
  def sources, do: @sources
end
