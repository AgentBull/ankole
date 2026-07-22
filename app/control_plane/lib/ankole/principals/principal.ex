defmodule Ankole.Principals.Principal do
  @moduledoc """
  Durable accountable subject shared by humans, agents, and installation services.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Agent
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.HumanUser

  @primary_key {:uid, Ankole.Ecto.PrincipalKey, []}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "principals" do
    field :type, Ecto.Enum, values: [:human, :agent, :system]
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :display_name, :string
    field :avatar_url, :string

    has_one :human_user, HumanUser, foreign_key: :principal_uid, references: :uid
    has_one :agent, Agent, foreign_key: :uid, references: :uid
    has_many :external_identities, ExternalIdentity, foreign_key: :principal_uid, references: :uid

    timestamps()
  end

  @doc """
  Builds a changeset for principal rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(principal, attrs) do
    principal
    |> cast(attrs, [:uid, :type, :status, :display_name, :avatar_url])
    |> normalize_blank([:uid, :display_name, :avatar_url])
    |> validate_required([:uid, :type, :status])
    |> unique_constraint(:uid, name: :principals_pkey)
    |> check_constraint(:uid, name: :principals_uid_present)
    |> check_constraint(:uid, name: :principals_uid_lowercase)
  end

  @doc """
  Builds a changeset for principal profile fields.
  """
  @spec profile_changeset(struct(), map()) :: Ecto.Changeset.t()
  def profile_changeset(principal, attrs) do
    principal
    |> cast(attrs, [:display_name, :avatar_url])
    |> normalize_blank([:display_name, :avatar_url])
  end

  @doc """
  Builds a changeset for principal status fields.
  """
  @spec status_changeset(struct(), map()) :: Ecto.Changeset.t()
  def status_changeset(principal, attrs) do
    principal
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end
end
