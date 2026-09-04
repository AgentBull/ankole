defmodule Ankole.TokenSigning do
  @moduledoc """
  Signs and verifies Ankole JWTs with the installation RSA key.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.OIDC.SigningKey

  @clock_leeway_seconds 60

  @spec issuer() :: String.t()
  def issuer, do: Boruta.Config.issuer() |> String.trim_trailing("/")

  @spec sign(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(claims, typ) when is_map(claims) and is_binary(typ) do
    with {:ok, key} <- SigningKey.get(),
         token when is_binary(token) <-
           NativeKernel.jwt_sign_pem(claims, key.private_key_pem, %{
             algorithm: "RS256",
             key_id: key.kid,
             typ: typ
           }) do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jwt_sign_failed, other}}
    end
  end

  @spec verify(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify(token, audience, typ)
      when is_binary(token) and is_binary(audience) and is_binary(typ) do
    with {:ok, key} <- SigningKey.get(),
         {:ok, header} <- peek_header(token),
         :ok <- require_header(header, "alg", "RS256"),
         :ok <- require_header(header, "kid", key.kid),
         :ok <- require_header(header, "typ", typ),
         claims when is_map(claims) <-
           NativeKernel.jwt_verify_jwk(token, key.public_jwk, validation(audience)) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jwt_verify_failed, other}}
    end
  end

  def verify(_token, _audience, _typ), do: {:error, :invalid_token}

  defp peek_header(token) do
    with [encoded | _parts] <- String.split(token, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, header} when is_map(header) <- Ankole.JSON.decode(json) do
      {:ok, header}
    else
      _invalid -> {:error, :invalid_jwt_header}
    end
  end

  defp require_header(header, field, expected) do
    if Map.get(header, field) == expected,
      do: :ok,
      else: {:error, {:invalid_jwt_header, field}}
  end

  defp validation(audience) do
    %{
      algorithms: ["RS256"],
      aud: [audience],
      iss: [issuer()],
      leeway: @clock_leeway_seconds,
      required_spec_claims: ["exp", "nbf", "aud", "iss", "sub"],
      validate_exp: true,
      validate_nbf: true
    }
  end
end
