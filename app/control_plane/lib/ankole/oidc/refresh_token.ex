defmodule Ankole.OIDC.RefreshToken do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.OIDC.Client
  alias Ankole.Principals.Principal

  @primary_key {:digest, :string, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oidc_refresh_tokens" do
    belongs_to :client, Client

    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :scope, :string
    field :issued_at, :utc_datetime_usec
    field :absolute_expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :digest,
      :client_id,
      :principal_uid,
      :scope,
      :issued_at,
      :absolute_expires_at
    ])
    |> validate_required([
      :digest,
      :client_id,
      :principal_uid,
      :scope,
      :issued_at,
      :absolute_expires_at
    ])
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:principal_uid)
  end
end
