defmodule Ankole.OIDC.Grant do
  @moduledoc """
  One OIDC Human's live authorization to call AI Gateway through one Client.
  """

  alias Ankole.OIDC
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.Tokens

  @enforce_keys [:client, :principal_uid, :access_token, :model_binding]
  defstruct [:client, :principal_uid, :access_token, :model_binding]

  @type t :: %__MODULE__{
          client: Client.t(),
          principal_uid: String.t(),
          access_token: String.t(),
          model_binding: map() | nil
        }

  @doc """
  Verifies the access token and applies the Client's current policy.

  A nil model means the request names no model, so only the Human, Client,
  scope, and group checks apply.
  """
  @spec authorize(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def authorize(access_token, model) when is_binary(access_token) do
    case Tokens.verify_access(access_token, Tokens.ai_gateway_audience()) do
      {:ok, claims} ->
        authorize_validated_claims(access_token, claims, model)

      {:error, _reason} ->
        {:error, :invalid_oidc_access}
    end
  end

  @doc """
  Applies current Client policy to claims from an AIGateway-verified token.

  The caller must obtain these claims by verifying this access token's
  signature, type, issuer, lifetime, and AIGateway audience through
  `Ankole.TokenSigning`.
  """
  @spec authorize_claims(String.t(), map(), String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def authorize_claims(access_token, claims, model)
      when is_binary(access_token) and is_map(claims) do
    case Tokens.validate_access_claims(claims) do
      {:ok, claims} -> authorize_validated_claims(access_token, claims, model)
      {:error, _reason} -> {:error, :invalid_oidc_access}
    end
  end

  def authorize_claims(_access_token, _claims, _model), do: {:error, :invalid_oidc_access}

  defp authorize_validated_claims(
         access_token,
         %{"client_id" => client_id, "sub" => principal_uid},
         model
       ) do
    with {:ok, %{client: client, model_binding: model_binding}} <-
           OIDC.authorize_ai_gateway(client_id, principal_uid, model) do
      {:ok,
       %__MODULE__{
         client: client,
         principal_uid: principal_uid,
         access_token: access_token,
         model_binding: model_binding
       }}
    end
  end
end
