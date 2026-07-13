defmodule Ankole.Plugins.Microsoft365Adapter.BotFrameworkAuth do
  @moduledoc """
  Bot Framework connector-to-bot request authentication.

  Implements the documented verification chain: RS256 signature against the
  Bot Framework JWKS, issuer `https://api.botframework.com`, audience equal to
  the bot's Microsoft App ID, five minutes of clock leeway, and a service-URL
  claim that must match the service URL on the activity. The library fetches
  and caches key documents; the signature itself is verified by the Rust
  kernel.

  The Emulator verification path (sts.windows.net issuers) is deliberately
  not implemented — only production connector traffic is accepted.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.Microsoft365Adapter.MapHelpers
  alias MicrosoftOpenAPI.BotOpenID

  @issuer "https://api.botframework.com"
  @leeway_seconds 300

  @doc """
  Verifies the Authorization header of one connector request.

  Returns the verified claims. `expected_app_id` is the Microsoft App ID the
  webhook instance segment named; the JWT audience must equal it.
  """
  @spec verify(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(headers, expected_app_id, activity, opts \\ [])
      when is_map(headers) and is_binary(expected_app_id) and is_map(activity) do
    with {:ok, token} <- bearer_token(headers),
         {:ok, kid} <- token_kid(token),
         {:ok, jwk} <- signing_jwk(kid, opts),
         {:ok, claims} <- verify_token(token, jwk),
         :ok <- verify_audience(claims, expected_app_id),
         :ok <- verify_service_url(claims, activity) do
      {:ok, claims}
    end
  end

  defp bearer_token(headers) do
    case Map.get(headers, "authorization") do
      "Bearer " <> token when token != "" -> {:ok, token}
      _missing -> {:error, :missing_bearer_token}
    end
  end

  # The kid is read from the unverified header only to select a key; nothing
  # is trusted until the kernel verifies the signature with that key.
  defp token_kid(token) do
    with [encoded_header, _payload, _signature] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, header} <- Torque.decode(header_json),
         kid when is_binary(kid) <- Map.get(header, "kid") do
      {:ok, kid}
    else
      _malformed -> {:error, :malformed_token}
    end
  end

  defp signing_jwk(kid, opts) do
    case BotOpenID.signing_jwk(kid, Keyword.take(opts, [:metadata_url, :req_options])) do
      {:ok, jwk} -> {:ok, jwk}
      {:error, :unknown_kid} -> {:error, :unknown_signing_key}
      {:error, reason} -> {:error, {:jwks_unavailable, reason}}
    end
  end

  defp verify_token(token, jwk) do
    case NativeKernel.jwt_verify_jwk(token, jwk, %{
           algorithms: ["RS256"],
           iss: [@issuer],
           leeway: @leeway_seconds
         }) do
      claims when is_map(claims) -> {:ok, claims}
      {:error, reason} -> {:error, {:invalid_token, reason}}
    end
  end

  # Audience is compared here rather than in kernel validation so the error
  # distinguishes a wrong-app token from a broken signature.
  defp verify_audience(claims, expected_app_id) do
    case Map.get(claims, "aud") do
      ^expected_app_id -> :ok
      [^expected_app_id] -> :ok
      _other -> {:error, :audience_mismatch}
    end
  end

  defp verify_service_url(claims, activity) do
    claimed = MapHelpers.optional_text(claims, "serviceUrl")
    activity_service_url = MapHelpers.optional_text(activity, "serviceUrl")

    cond do
      is_nil(claimed) -> {:error, :missing_service_url_claim}
      normalize_url(claimed) == normalize_url(activity_service_url) -> :ok
      true -> {:error, :service_url_mismatch}
    end
  end

  defp normalize_url(nil), do: nil
  defp normalize_url(url), do: String.trim_trailing(url, "/")
end
