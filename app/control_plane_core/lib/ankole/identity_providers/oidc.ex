defmodule Ankole.IdentityProviders.OIDC do
  @moduledoc """
  Verifies the upstream proof of an identity-provider login.

  An adapter exchanges the authorization code and gives the token, the claims
  of the provider's user endpoint, and the user. It declares the expected ID
  token with `id_token_verification/1`: the issuer, the client ID, and the
  claim that identifies the user. `verify_login/3` is the only function that
  verifies the ID token and binds it to the user endpoint claims. An adapter
  whose provider gives no ID token declares `:none`. Such a login has no
  authentication time.
  """

  @type verification ::
          %{issuer: String.t(), client_id: String.t(), subject_claim: String.t()} | :none

  @doc """
  Verifies the login proof and gives the signed authentication time.

  The result is `{:ok, auth_time}`. `auth_time` is `nil` when the provider did
  not sign one.
  """
  @spec verify_login(verification(), map(), keyword()) ::
          {:ok, integer() | nil} | {:error, term()}
  def verify_login(
        %{issuer: issuer, client_id: client_id, subject_claim: subject_claim},
        %{token: token, claims: claims},
        opts
      )
      when is_binary(issuer) and is_binary(client_id) and is_binary(subject_claim) and
             is_map(claims) do
    with {:ok, verified} <- verify(token, issuer, client_id, opts),
         :ok <- bind_subject(verified, claims, subject_claim) do
      {:ok, verified["auth_time"]}
    end
  end

  def verify_login(:none, _login, opts) do
    with :ok <- validate_authentication_time(nil, opts), do: {:ok, nil}
  end

  def verify_login(_verification, _login, _opts), do: {:error, :invalid_oidc_login}

  defp verify(token, issuer, client_id, opts) do
    with nonce when is_binary(nonce) and nonce != "" <- Keyword.get(opts, :nonce),
         {:ok, claims} <-
           AttestoClient.IDToken.verify(token.id_token,
             issuer: issuer,
             client_id: client_id,
             nonce: nonce,
             access_token: token.access_token,
             req_options: Req.default_options(),
             max_age: verification_max_age(opts)
           ),
         :ok <- validate_authentication_time(claims["auth_time"], opts) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, {:invalid_id_token, reason}}
      _invalid_nonce -> {:error, :oidc_nonce_required}
    end
  end

  defp validate_authentication_time(auth_time, opts) do
    cond do
      Keyword.get(opts, :auth_time_required, false) and not is_integer(auth_time) ->
        {:error, :authentication_time_unavailable}

      is_integer(Keyword.get(opts, :auth_time_not_before)) and
          (not is_integer(auth_time) or auth_time < Keyword.fetch!(opts, :auth_time_not_before)) ->
        {:error, :authentication_too_old}

      true ->
        :ok
    end
  end

  # The user endpoint must describe the user that the signed ID token names.
  defp bind_subject(verified, claims, subject_claim) do
    case {verified[subject_claim], claims[subject_claim]} do
      {subject, subject} when is_binary(subject) -> :ok
      _mismatch -> {:error, :oidc_subject_mismatch}
    end
  end

  defp verification_max_age(opts) do
    case Keyword.get(opts, :max_age) do
      0 -> nil
      value -> value
    end
  end
end
