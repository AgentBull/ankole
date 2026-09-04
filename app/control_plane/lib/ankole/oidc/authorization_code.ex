defmodule Ankole.OIDC.AuthorizationCode do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.OIDC.Client
  alias Ankole.Principals.Principal

  @primary_key {:digest, :string, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "oidc_authorization_codes" do
    belongs_to :client, Client

    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :redirect_uri, :string
    field :scope, :string
    field :state, :string
    field :nonce, :string
    field :code_challenge_digest, :string
    field :code_challenge_method, :string
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, [
      :digest,
      :client_id,
      :principal_uid,
      :redirect_uri,
      :scope,
      :state,
      :nonce,
      :code_challenge_digest,
      :code_challenge_method,
      :expires_at
    ])
    |> validate_required([
      :digest,
      :client_id,
      :principal_uid,
      :redirect_uri,
      :scope,
      :code_challenge_digest,
      :code_challenge_method,
      :expires_at
    ])
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:principal_uid)
    |> check_constraint(:code_challenge_method, name: :oidc_authorization_codes_pkce_s256)
  end
end
