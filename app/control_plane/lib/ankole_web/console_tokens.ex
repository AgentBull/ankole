defmodule AnkoleWeb.ConsoleTokens do
  @moduledoc """
  JWT token bridge for the browser console API.

  The cookie admin session remains the login root. These JWTs are short-lived
  bearer credentials derived from that session so `/api/v1/*` can stay stateless
  and separate from browser-session JSON endpoints.
  """

  alias Ankole.Kernel, as: NativeKernel

  @issuer "ankole.control_plane"
  @audience "ankole.web_console"
  @scope "web_console"
  @access_token_use "access"
  @refresh_token_use "refresh"
  @access_sub_key_id "web_console.jwt.access"
  @refresh_sub_key_id "web_console.jwt.refresh"
  @access_ttl_seconds 30 * 60
  @refresh_ttl_seconds 24 * 60 * 60
  @clock_leeway_seconds 60

  @type token_set :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          refresh_token_expires_in: pos_integer(),
          scope: String.t()
        }

  @doc """
  Mints an access/refresh token set from an active browser admin session.
  """
  @spec mint_for_session(map()) :: {:ok, token_set()} | {:error, term()}
  def mint_for_session(%{"principal_uid" => principal_uid} = session)
      when is_binary(principal_uid) do
    now = now_seconds()

    with {:ok, session_exp} <- session_expires_at(session),
         {:ok, sid_hash} <- sid_hash(session),
         {:ok, access_token, access_ttl} <-
           sign_token(
             @access_token_use,
             principal_uid,
             sid_hash,
             now,
             access_expires_at(now, session_exp)
           ),
         {:ok, refresh_token, refresh_ttl} <-
           sign_token(
             @refresh_token_use,
             principal_uid,
             sid_hash,
             now,
             refresh_expires_at(now, session_exp)
           ) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         token_type: "Bearer",
         expires_in: access_ttl,
         refresh_token_expires_in: refresh_ttl,
         scope: @scope
       }}
    end
  end

  def mint_for_session(_session), do: {:error, :invalid_admin_session}

  @doc """
  Verifies a refresh token against the current browser admin session and remints.
  """
  @spec refresh_for_session(String.t(), map()) :: {:ok, token_set()} | {:error, term()}
  def refresh_for_session(refresh_token, %{"principal_uid" => principal_uid} = session)
      when is_binary(refresh_token) and is_binary(principal_uid) do
    with {:ok, claims} <- verify_refresh_token(refresh_token),
         :ok <- require_claim(claims, "token_use", @refresh_token_use),
         :ok <- require_claim(claims, "scope", @scope),
         :ok <- require_claim(claims, "sub", principal_uid),
         {:ok, expected_sid_hash} <- sid_hash(session),
         :ok <- require_claim(claims, "sid_hash", expected_sid_hash) do
      mint_for_session(session)
    end
  end

  def refresh_for_session(_refresh_token, _session), do: {:error, :invalid_admin_session}

  @doc """
  Verifies an access token and returns the token claims.
  """
  @spec verify_access_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_access_token(token) when is_binary(token) do
    with {:ok, claims} <- verify_token(token, :access),
         :ok <- require_claim(claims, "token_use", @access_token_use),
         :ok <- require_claim(claims, "scope", @scope),
         %{"sub" => sub} <- claims,
         true <- is_binary(sub) and sub != "" do
      {:ok, claims}
    else
      false -> {:error, :invalid_subject}
      %{} -> {:error, :invalid_subject}
      {:error, _reason} = error -> error
    end
  end

  def verify_access_token(_token), do: {:error, :invalid_token}

  defp verify_refresh_token(token), do: verify_token(token, :refresh)

  defp verify_token(token, token_kind) do
    with {:ok, key} <- signing_key(token_kind),
         claims when is_map(claims) <- NativeKernel.jwt_verify(token, key, validation()) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jwt_verify_failed, other}}
    end
  end

  # `expires_at` is already capped to the session expiry by the callers, so a
  # non-positive ttl means the underlying browser session has lapsed — refuse to
  # mint rather than issue an already-dead token.
  defp sign_token(token_use, principal_uid, sid_hash, now, expires_at) do
    ttl = expires_at - now

    case ttl > 0 do
      true ->
        claims = %{
          aud: @audience,
          exp: expires_at,
          iat: now,
          iss: @issuer,
          jti: NativeKernel.gen_uuid_v7(),
          nbf: now,
          scope: @scope,
          sid_hash: sid_hash,
          sub: principal_uid,
          token_use: token_use
        }

        with {:ok, key} <- signing_key(token_use),
             token when is_binary(token) <-
               NativeKernel.jwt_sign(claims, key, %{algorithm: "HS256"}) do
          {:ok, token, ttl}
        else
          {:error, reason} -> {:error, reason}
          other -> {:error, {:jwt_sign_failed, other}}
        end

      false ->
        {:error, :admin_session_expired}
    end
  end

  # Access and refresh tokens are signed under different derived keys, so a
  # refresh token can never be presented (or mistaken) as an access token even
  # though both are HS256 over the same root secret.
  defp signing_key(@access_token_use), do: signing_key(:access)
  defp signing_key(@refresh_token_use), do: signing_key(:refresh)

  defp signing_key(:access), do: derive_signing_key(@access_sub_key_id)
  defp signing_key(:refresh), do: derive_signing_key(@refresh_sub_key_id)

  defp derive_signing_key(sub_key_id) do
    with {:ok, secret} <- root_secret(),
         key when is_binary(key) <- NativeKernel.derive_key(secret, sub_key_id, nil) do
      {:ok, key}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:derive_key_failed, other}}
    end
  end

  defp validation do
    %{
      algorithms: ["HS256"],
      aud: [@audience],
      iss: [@issuer],
      leeway: @clock_leeway_seconds,
      required_spec_claims: ["exp", "nbf", "aud", "iss", "sub"],
      validate_exp: true,
      validate_nbf: true
    }
  end

  # Binds a token to the exact admin session that produced it. The hash covers the
  # session's identifying fields; on refresh we recompute it and require a match,
  # so a token stops working the moment the session is renewed or replaced (e.g.
  # after a re-login), even if the principal is the same. Keys are sorted so the
  # hash is stable regardless of map ordering.
  defp sid_hash(session) do
    payload =
      session
      |> Map.take(["principal_uid", "provider_id", "external_id", "issued_at", "expires_at"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [key, value] end)

    with {:ok, json} <- Ankole.JSON.encode(payload),
         hash when is_binary(hash) <- NativeKernel.generic_hash(json) do
      {:ok, hash}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:sid_hash_failed, other}}
    end
  end

  defp require_claim(claims, key, expected) do
    case Map.fetch(claims, key) do
      {:ok, ^expected} -> :ok
      {:ok, _value} -> {:error, {:invalid_claim, key}}
      :error -> {:error, {:missing_claim, key}}
    end
  end

  # Token lifetime is the lesser of its own TTL and the remaining browser session
  # — a console token can never outlive the cookie session it was derived from.
  defp access_expires_at(now, session_exp), do: min(now + @access_ttl_seconds, session_exp)
  defp refresh_expires_at(now, session_exp), do: min(now + @refresh_ttl_seconds, session_exp)

  defp session_expires_at(%{"expires_at" => expires_at}) when is_integer(expires_at) do
    {:ok, expires_at}
  end

  defp session_expires_at(_session), do: {:error, :invalid_admin_session_expiry}

  # Reads the endpoint secret straight from config (not from a conn) because
  # signing/verifying tokens is not always inside a request. All JWT keys derive
  # from this one root secret via distinct sub-key ids.
  defp root_secret do
    :ankole
    |> Application.get_env(AnkoleWeb.Endpoint, [])
    |> Keyword.fetch(:secret_key_base)
    |> case do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_secret_key_base}
      :error -> {:error, :missing_secret_key_base}
    end
  end

  defp now_seconds, do: System.system_time(:second)
end
