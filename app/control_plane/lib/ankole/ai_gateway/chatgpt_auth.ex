defmodule Ankole.AIGateway.ChatGPTAuth do
  @moduledoc """
  ChatGPT OAuth login and credential refresh for AIGateway provider pools.

  Login polling state stays in the Console client. The control plane stores
  only completed credentials in the owning provider row. Token refresh uses the
  same row lock as credential writes so a rotating refresh token is consumed by
  at most one control-plane request at a time.
  """

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_issuer "https://auth.openai.com"
  @device_lifetime_seconds 15 * 60
  @access_refresh_window_seconds 5 * 60
  @last_refresh_interval_seconds 8 * 24 * 60 * 60
  @browser_redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid email profile offline_access"
  @permanent_refresh_codes ~w(
    refresh_token_expired
    refresh_token_reused
    refresh_token_invalidated
    invalid_grant
    token_revoked
    refresh_token_revoked
  )

  @doc """
  Starts one ChatGPT login.

  Device login is preferred. If the issuer does not provide the device route,
  this returns a browser URL and one-time PKCE context for the paste-callback
  fallback. No polling tuple is stored on the server.
  """
  @spec start_login(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_login(provider_id, attrs \\ %{}, opts \\ [])
      when is_binary(provider_id) and is_map(attrs) do
    with {:ok, provider} <- chatgpt_provider(provider_id),
         {:ok, issuer} <- issuer(provider),
         {:ok, response} <-
           request(
             :post,
             "#{issuer}/api/accounts/deviceauth/usercode",
             [json: %{"client_id" => @client_id}],
             opts
           ) do
      case response.status do
        status when status in 200..299 ->
          device_login_response(response.body, issuer, attrs, opts)

        404 ->
          {:ok, browser_login_response(issuer, attrs, opts)}

        status ->
          {:error, {:device_login_failed, status, response_error_code(response.body)}}
      end
    end
  end

  @doc """
  Polls a device-login tuple once.

  A pending response tells the Console when to poll again. A completed response
  exchanges the authorization code and appends the credential to the provider
  pool.
  """
  @spec poll_login(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll_login(provider_id, login_context, opts \\ [])
      when is_binary(provider_id) and is_map(login_context) do
    with {:ok, context} <- normalize_device_context(login_context, opts),
         {:ok, provider} <- chatgpt_provider(provider_id),
         {:ok, issuer} <- matching_issuer(provider, context),
         {:ok, response} <-
           request(
             :post,
             "#{issuer}/api/accounts/deviceauth/token",
             [
               json: %{
                 "device_auth_id" => context.device_auth_id,
                 "user_code" => context.user_code
               }
             ],
             opts
           ) do
      case response.status do
        status when status in 200..299 ->
          with {:ok, code} <- required_text(response.body, "authorization_code"),
               {:ok, verifier} <- required_text(response.body, "code_verifier"),
               {:ok, challenge} <- required_text(response.body, "code_challenge"),
               :ok <- verify_pkce_pair(verifier, challenge),
               {:ok, tokens} <-
                 exchange_code(issuer, code, verifier, "#{issuer}/deviceauth/callback", opts),
               {:ok, provider} <-
                 store_tokens(provider_id, tokens, context.credential_attrs, opts) do
            {:ok,
             %{
               "status" => "complete",
               "ai_gateway_provider" => ProviderConfigs.projection(provider)
             }}
          end

        status when status in [403, 404] ->
          {:ok,
           %{
             "status" => "pending",
             "retry_after" => context.interval,
             "expires_at" => expires_at(context.issued_at)
           }}

        status ->
          {:error, {:device_login_failed, status, response_error_code(response.body)}}
      end
    end
  end

  @doc """
  Completes the browser fallback from a pasted callback URL.
  """
  @spec complete_browser_login(String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_browser_login(provider_id, login_context, callback_url, opts \\ [])
      when is_binary(provider_id) and is_map(login_context) and is_binary(callback_url) do
    with {:ok, context} <- normalize_browser_context(login_context, opts),
         {:ok, provider} <- chatgpt_provider(provider_id),
         {:ok, issuer} <- matching_issuer(provider, context),
         {:ok, params} <- callback_params(callback_url),
         :ok <- verify_callback_state(params, context.state),
         {:ok, code} <- required_text(params, "code"),
         {:ok, tokens} <-
           exchange_code(issuer, code, context.code_verifier, @browser_redirect_uri, opts),
         {:ok, provider} <-
           store_tokens(provider_id, tokens, context.credential_attrs, opts) do
      {:ok,
       %{
         "status" => "complete",
         "ai_gateway_provider" => ProviderConfigs.projection(provider)
       }}
    end
  end

  @doc """
  Adds a manually issued enterprise access token.
  """
  @spec add_enterprise_credential(String.t(), map()) ::
          {:ok, Provider.t()} | {:error, term()}
  def add_enterprise_credential(provider_id, attrs)
      when is_binary(provider_id) and is_map(attrs) do
    attrs = normalize_keys(attrs)

    with {:ok, _provider} <- chatgpt_provider(provider_id),
         {:ok, access_token} <- required_text(attrs, "access_token"),
         {:ok, account_id} <- required_text(attrs, "account_id") do
      credential =
        attrs
        |> Map.take(~w(id label priority disabled_at account_id plan_type email fedramp))
        |> Map.put("access_token", strip_bearer(access_token))
        |> Map.put("account_id", account_id)
        |> Map.put("auth_type", "enterprise_access_token")
        |> Map.put("source", "enterprise_access_token")

      store_credential(provider_id, credential)
    end
  end

  @doc """
  Refreshes a selected OAuth credential when it is near expiry or stale.
  """
  @spec ensure_fresh(Provider.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_fresh(%Provider{} = provider, %{"credential" => credential} = selected, opts \\ []) do
    if provider.provider_kind == "chatgpt_subscription" and oauth?(credential) and
         refresh_required?(credential, opts) do
      with {:ok, refreshed} <-
             refresh_credential(provider.provider_id, selected["id"], opts) do
        {:ok,
         selected
         |> Map.put("credential", refreshed["credential"])
         |> Map.put("entry", refreshed["entry"])}
      end
    else
      {:ok, selected}
    end
  end

  @doc """
  Forces one OAuth refresh for a credential.

  This is used once after an upstream 401 before the credential is marked
  unavailable. Enterprise access tokens cannot be refreshed.
  """
  @spec force_refresh(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def force_refresh(provider_id, credential_id, opts \\ []) do
    refresh_credential(provider_id, credential_id, Keyword.put(opts, :force, true))
  end

  @doc false
  def client_id, do: @client_id

  defp refresh_credential(provider_id, credential_id, opts) do
    ProviderConfigs.update_credential_under_lock(
      provider_id,
      credential_id,
      fn provider, entry, credential ->
        result =
          cond do
            not oauth?(credential) ->
              {:error, :credential_not_refreshable}

            force_already_satisfied?(credential, opts) ->
              {:ok, :unchanged}

            not Keyword.get(opts, :force, false) and not refresh_required?(credential, opts) ->
              {:ok, :unchanged}

            true ->
              refresh_from_authority(provider, credential, opts)
          end

        record_refresh_health(provider, entry, result)
      end
    )
  end

  defp record_refresh_health(
         provider,
         entry,
         {:error, {:chatgpt_refresh_permanent, _reason}} = error
       ) do
    :ok = CredentialPool.mark_dead(provider.id, entry)
    error
  end

  defp record_refresh_health(
         provider,
         entry,
         {:error, {:chatgpt_refresh_transient, 429, headers, _reason}} = error
       ) do
    :ok = CredentialPool.mark_exhausted(provider.id, entry, 429, headers)
    error
  end

  defp record_refresh_health(_provider, _entry, result), do: result

  defp refresh_from_authority(provider, credential, opts) do
    with {:ok, refresh_token} <- required_text(credential, "refresh_token"),
         {:ok, issuer} <- issuer(provider),
         {:ok, response} <-
           request(
             :post,
             "#{issuer}/oauth/token",
             [
               json: %{
                 "client_id" => @client_id,
                 "grant_type" => "refresh_token",
                 "refresh_token" => refresh_token
               }
             ],
             opts
           ) do
      case response.status do
        status when status in 200..299 ->
          with {:ok, updated} <- merge_refreshed_tokens(credential, response.body, opts),
               :ok <- same_account(credential, updated) do
            {:ok, updated}
          end

        status ->
          code = response_error_code(response.body)

          if status == 401 or code in @permanent_refresh_codes do
            {:error, {:chatgpt_refresh_permanent, code || "unauthorized"}}
          else
            {:error,
             {:chatgpt_refresh_transient, status, response.headers, code || "refresh_failed"}}
          end
      end
    else
      {:error, :missing_refresh_token} ->
        {:error, {:chatgpt_refresh_permanent, "missing_refresh_token"}}

      {:error, {:request_failed, reason}} ->
        {:error, {:chatgpt_refresh_transient, nil, %{}, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp merge_refreshed_tokens(credential, body, opts) when is_map(body) do
    tokens =
      ~w(access_token refresh_token id_token)
      |> Enum.reduce(credential, fn key, acc ->
        case Map.get(body, key) do
          value when is_binary(value) and value != "" -> Map.put(acc, key, value)
          _value -> acc
        end
      end)

    with {:ok, access_token} <- required_text(tokens, "access_token") do
      metadata =
        case Map.get(tokens, "id_token") do
          id_token when is_binary(id_token) and id_token != "" -> token_metadata(id_token)
          _value -> token_metadata(access_token)
        end

      {:ok,
       tokens
       |> Map.merge(metadata)
       |> Map.put("last_refresh", now(opts) |> DateTime.to_iso8601())
       |> Map.put("auth_type", "oauth")}
    end
  end

  defp merge_refreshed_tokens(_credential, _body, _opts),
    do: {:error, {:chatgpt_refresh_transient, nil, %{}, "invalid_response"}}

  defp same_account(existing, updated) do
    previous = Map.get(existing, "account_id")
    current = Map.get(updated, "account_id")

    if is_binary(previous) and is_binary(current) and previous != current do
      {:error, {:chatgpt_refresh_permanent, "account_changed"}}
    else
      :ok
    end
  end

  defp store_tokens(provider_id, tokens, attrs, opts) do
    attrs = normalize_keys(attrs)

    with {:ok, access_token} <- required_text(tokens, "access_token"),
         {:ok, refresh_token} <- required_text(tokens, "refresh_token"),
         {:ok, id_token} <- required_text(tokens, "id_token") do
      credential =
        attrs
        |> Map.take(~w(id label priority disabled_at source))
        |> Map.merge(token_metadata(id_token))
        |> Map.merge(%{
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "id_token" => id_token,
          "last_refresh" => now(opts) |> DateTime.to_iso8601(),
          "auth_type" => "oauth"
        })

      with {:ok, _account_id} <- required_text(credential, "account_id") do
        store_credential(provider_id, credential)
      end
    end
  end

  defp device_login_response(body, issuer, attrs, opts) when is_map(body) do
    with {:ok, device_auth_id} <- required_text(body, "device_auth_id"),
         {:ok, user_code} <- required_text_alias(body, ~w(user_code usercode)),
         {:ok, interval} <- poll_interval(Map.get(body, "interval")) do
      issued_at = now(opts) |> DateTime.to_iso8601()

      {:ok,
       %{
         "mode" => "device",
         "verification_url" =>
           optional_text(body, "verification_url") || "#{issuer}/codex/device",
         "user_code" => user_code,
         "interval" => interval,
         "expires_at" => expires_at(issued_at),
         "login_context" => %{
           "mode" => "device",
           "issuer" => issuer,
           "device_auth_id" => device_auth_id,
           "user_code" => user_code,
           "interval" => interval,
           "issued_at" => issued_at,
           "credential" =>
             attrs
             |> credential_attrs()
             |> Map.put("source", "device_oauth")
         }
       }}
    end
  end

  defp device_login_response(_body, _issuer, _attrs, _opts),
    do: {:error, :invalid_device_login_response}

  defp browser_login_response(issuer, attrs, opts) do
    verifier = random_url_token(64)
    challenge = pkce_challenge(verifier)
    state = random_url_token(32)
    issued_at = now(opts) |> DateTime.to_iso8601()

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => @browser_redirect_uri,
        "scope" => @scope,
        "prompt" => "login",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "state" => state,
        "originator" => "codex_cli_rs"
      })

    %{
      "mode" => "browser_paste",
      "authorization_url" => "#{issuer}/oauth/authorize?#{query}",
      "redirect_uri" => @browser_redirect_uri,
      "expires_at" => expires_at(issued_at),
      "login_context" => %{
        "mode" => "browser_paste",
        "issuer" => issuer,
        "code_verifier" => verifier,
        "state" => state,
        "issued_at" => issued_at,
        "credential" =>
          attrs
          |> credential_attrs()
          |> Map.put("source", "browser_oauth")
      }
    }
  end

  defp exchange_code(issuer, code, verifier, redirect_uri, opts) do
    with {:ok, response} <-
           request(
             :post,
             "#{issuer}/oauth/token",
             [
               form: %{
                 "grant_type" => "authorization_code",
                 "code" => code,
                 "redirect_uri" => redirect_uri,
                 "client_id" => @client_id,
                 "code_verifier" => verifier
               }
             ],
             opts
           ) do
      case response.status do
        status when status in 200..299 and is_map(response.body) ->
          {:ok, response.body}

        status ->
          {:error, {:token_exchange_failed, status, response_error_code(response.body)}}
      end
    end
  end

  defp normalize_device_context(context, opts) do
    context = normalize_keys(context)

    with "device" <- Map.get(context, "mode"),
         {:ok, issuer} <- required_text(context, "issuer"),
         {:ok, device_auth_id} <- required_text(context, "device_auth_id"),
         {:ok, user_code} <- required_text(context, "user_code"),
         {:ok, interval} <- poll_interval(Map.get(context, "interval")),
         {:ok, issued_at} <- unexpired_issued_at(Map.get(context, "issued_at"), opts) do
      {:ok,
       %{
         issuer: issuer,
         device_auth_id: device_auth_id,
         user_code: user_code,
         interval: interval,
         issued_at: issued_at,
         credential_attrs: credential_attrs(Map.get(context, "credential", %{}))
       }}
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_login_context}
    end
  end

  defp normalize_browser_context(context, opts) do
    context = normalize_keys(context)

    with "browser_paste" <- Map.get(context, "mode"),
         {:ok, issuer} <- required_text(context, "issuer"),
         {:ok, verifier} <- required_text(context, "code_verifier"),
         true <- byte_size(verifier) in 43..128,
         {:ok, state} <- required_text(context, "state"),
         {:ok, issued_at} <- unexpired_issued_at(Map.get(context, "issued_at"), opts) do
      {:ok,
       %{
         issuer: issuer,
         code_verifier: verifier,
         state: state,
         issued_at: issued_at,
         credential_attrs: credential_attrs(Map.get(context, "credential", %{}))
       }}
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_login_context}
    end
  end

  defp callback_params(callback_url) do
    with {:ok, uri} <- URI.new(String.trim(callback_url)),
         query when is_binary(query) <- uri.query do
      {:ok, URI.decode_query(query)}
    else
      _value -> {:error, :invalid_callback_url}
    end
  end

  defp verify_callback_state(params, expected) do
    cond do
      Map.get(params, "state") != expected -> {:error, :oauth_state_mismatch}
      is_binary(Map.get(params, "error")) -> {:error, {:oauth_denied, Map.get(params, "error")}}
      true -> :ok
    end
  end

  defp unexpired_issued_at(value, opts) when is_binary(value) do
    with {:ok, issued_at, _offset} <- DateTime.from_iso8601(value),
         true <- DateTime.compare(issued_at, now(opts)) != :gt,
         true <- DateTime.diff(now(opts), issued_at, :second) <= @device_lifetime_seconds do
      {:ok, DateTime.to_iso8601(issued_at)}
    else
      false -> {:error, :login_expired}
      _value -> {:error, :invalid_login_context}
    end
  end

  defp unexpired_issued_at(_value, _opts), do: {:error, :invalid_login_context}

  defp matching_issuer(provider, %{issuer: context_issuer}) do
    with {:ok, provider_issuer} <- issuer(provider),
         true <- provider_issuer == context_issuer do
      {:ok, provider_issuer}
    else
      false -> {:error, :login_issuer_changed}
      {:error, _reason} = error -> error
    end
  end

  defp issuer(%Provider{connection_options: options}) do
    value =
      case options do
        %{} -> Map.get(options, "auth_issuer", @default_issuer)
        _value -> @default_issuer
      end

    with value when is_binary(value) <- value,
         value <- String.trim_trailing(String.trim(value), "/"),
         {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] <-
           URI.new(value),
         true <- is_binary(host) and host != "" do
      {:ok, value}
    else
      _value -> {:error, :invalid_auth_issuer}
    end
  end

  defp chatgpt_provider(provider_id) do
    with {:ok, %Provider{} = provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         true <- provider.provider_kind == "chatgpt_subscription" do
      {:ok, provider}
    else
      false -> {:error, :provider_not_chatgpt_subscription}
      {:error, _reason} = error -> error
    end
  end

  defp refresh_required?(credential, opts) do
    now = now(opts)

    near_expiry? =
      case jwt_expiration(Map.get(credential, "access_token")) do
        {:ok, %DateTime{} = expiration} ->
          DateTime.diff(expiration, now, :second) <= @access_refresh_window_seconds

        _value ->
          false
      end

    stale_refresh? =
      case Map.get(credential, "last_refresh") do
        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, refreshed_at, _offset} ->
              DateTime.diff(now, refreshed_at, :second) >= @last_refresh_interval_seconds

            _value ->
              false
          end

        _value ->
          false
      end

    near_expiry? or stale_refresh?
  end

  defp force_already_satisfied?(credential, opts) do
    case Keyword.get(opts, :expected_access_token) do
      expected when is_binary(expected) and expected != "" ->
        Keyword.get(opts, :force, false) and
          Map.get(credential, "access_token") != expected

      _missing ->
        false
    end
  end

  defp oauth?(credential), do: Map.get(credential, "auth_type", "oauth") == "oauth"

  defp token_metadata(token) do
    case jwt_payload(token) do
      {:ok, claims} ->
        auth = Map.get(claims, "https://api.openai.com/auth", %{})
        profile = Map.get(claims, "https://api.openai.com/profile", %{})

        %{
          "account_id" => text_or_nil(Map.get(auth, "chatgpt_account_id")),
          "plan_type" => text_or_nil(Map.get(auth, "chatgpt_plan_type")),
          "email" =>
            text_or_nil(Map.get(claims, "email")) || text_or_nil(Map.get(profile, "email")),
          "fedramp" => Map.get(auth, "chatgpt_account_is_fedramp") == true
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:error, _reason} ->
        %{}
    end
  end

  defp jwt_expiration(token) do
    with {:ok, payload} <- jwt_payload(token),
         expiration when is_integer(expiration) <- Map.get(payload, "exp"),
         %DateTime{} = datetime <- DateTime.from_unix!(expiration) do
      {:ok, datetime}
    else
      _value -> {:error, :invalid_jwt_expiration}
    end
  rescue
    _error -> {:error, :invalid_jwt_expiration}
  end

  defp jwt_payload(token) when is_binary(token) do
    case String.split(token, ".", parts: 4) do
      [_header, payload, _signature] when payload != "" ->
        with {:ok, json} <- Base.url_decode64(payload, padding: false),
             {:ok, %{} = claims} <- Ankole.JSON.decode(json) do
          {:ok, claims}
        else
          _value -> {:error, :invalid_jwt}
        end

      _parts ->
        {:error, :invalid_jwt}
    end
  end

  defp jwt_payload(_token), do: {:error, :invalid_jwt}

  defp verify_pkce_pair(verifier, expected_challenge) do
    if pkce_challenge(verifier) == expected_challenge do
      :ok
    else
      {:error, :invalid_device_pkce}
    end
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp random_url_token(bytes) do
    :crypto.strong_rand_bytes(bytes)
    |> Base.url_encode64(padding: false)
  end

  defp request(method, url, request_options, opts) do
    options =
      [
        method: method,
        url: url,
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
      ] ++ request_options ++ Keyword.get(opts, :req_options, [])

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           body: response.body,
           headers: response.headers
         }}

      {:error, reason} ->
        {:error, {:request_failed, request_error(reason)}}
    end
  end

  defp request_error(%Req.TransportError{reason: reason}), do: reason
  defp request_error(_reason), do: :transport_error

  defp response_error_code(body) when is_map(body) do
    case Map.get(body, "error") do
      %{} = error -> text_or_nil(Map.get(error, "code")) || text_or_nil(Map.get(error, "type"))
      value when is_binary(value) -> value
      _value -> text_or_nil(Map.get(body, "code"))
    end
  end

  defp response_error_code(_body), do: nil

  defp credential_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_keys()
    |> Map.take(~w(id label priority disabled_at source))
  end

  defp credential_attrs(_attrs), do: %{}

  defp store_credential(provider_id, %{"id" => credential_id} = credential)
       when is_binary(credential_id) and credential_id != "" do
    case ProviderConfigs.update_credential(provider_id, credential_id, credential) do
      {:error, :credential_not_found} ->
        ProviderConfigs.add_credential(provider_id, credential)

      result ->
        result
    end
  end

  defp store_credential(provider_id, credential),
    do: ProviderConfigs.add_credential(provider_id, credential)

  defp poll_interval(value) when is_integer(value) and value in 1..60, do: {:ok, value}

  defp poll_interval(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {interval, ""} -> poll_interval(interval)
      _value -> {:error, :invalid_device_poll_interval}
    end
  end

  defp poll_interval(_value), do: {:error, :invalid_device_poll_interval}

  defp required_text(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, missing_key(key)}
          value -> {:ok, value}
        end

      _value ->
        {:error, missing_key(key)}
    end
  end

  defp required_text(_map, key), do: {:error, missing_key(key)}

  defp required_text_alias(map, keys) do
    Enum.find_value(keys, {:error, missing_key(List.first(keys))}, fn key ->
      case required_text(map, key) do
        {:ok, value} -> {:ok, value}
        {:error, _reason} -> nil
      end
    end)
  end

  defp optional_text(map, key) do
    case required_text(map, key) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp missing_key("refresh_token"), do: :missing_refresh_token
  defp missing_key(key), do: {:missing, key}

  defp expires_at(issued_at) when is_binary(issued_at) do
    {:ok, issued_at, _offset} = DateTime.from_iso8601(issued_at)
    issued_at |> DateTime.add(@device_lifetime_seconds, :second) |> DateTime.to_iso8601()
  end

  defp strip_bearer(value), do: String.replace_prefix(value, "Bearer ", "")

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      fun when is_function(fun, 0) -> fun.()
      _value -> DateTime.utc_now(:second)
    end
  end

  defp text_or_nil(value) when is_binary(value) and value != "", do: value
  defp text_or_nil(_value), do: nil
end
