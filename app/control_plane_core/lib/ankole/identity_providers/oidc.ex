defmodule Ankole.IdentityProviders.OIDC do
  @moduledoc false

  def verify(token, issuer, client_id, opts) do
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

  def validate_authentication_time(auth_time, opts) do
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

  def bind_subject(%{"sub" => subject}, %{"sub" => subject}) when is_binary(subject), do: :ok
  def bind_subject(_, _), do: {:error, :oidc_subject_mismatch}

  defp verification_max_age(opts) do
    case Keyword.get(opts, :max_age) do
      0 -> nil
      value -> value
    end
  end
end
