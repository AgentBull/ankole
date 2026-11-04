defmodule Ankole.Plugins.GitHubAdapter.Connector do
  @moduledoc "GitHub's explicit REST Toolkit and first-party application authentication."
  @behaviour Ankole.Connectors.Connector
  alias Ankole.Connectors.HTTP
  alias Ankole.Plugins.GitHubAdapter.Tools
  defdelegate tools(), to: Tools

  def call(%{name: name} = tool, args, context)
      when name in ["actions_get_run_logs", "actions_download_artifact"] do
    args =
      if name == "actions_download_artifact",
        do: Map.put_new(args, "archive_format", "zip"),
        else: args

    with {:ok, url, _} <- HTTP.request_parts(tool.operation, args, base_url(context.auth_config)) do
      Ankole.Connectors.Files.download(
        context.actor,
        url,
        headers(context.access_token),
        args["destination"],
        request_options(context)
      )
    end
  end

  def call(%{name: "releases_upload_asset"} = tool, args, context) do
    base =
      configured_url(
        context.auth_config,
        "uploads_url",
        uploads_url(base_url(context.auth_config))
      )

    with {:ok, url, _} <- HTTP.request_parts(tool.operation, args, base),
         {:ok, response} <-
           Ankole.Files.HTTP.upload(
             context.actor,
             args["file_ref"],
             "POST",
             url,
             [
               {"content-type", args["content_type"]} | auth_headers(context.access_token)
             ],
             request_options(context)
           ) do
      decode(response, auth_headers(context.access_token))
    end
  end

  def call(tool, args, context) do
    with {:ok, result} <-
           HTTP.call(
             tool,
             args,
             base_url(context.auth_config),
             headers(context.access_token),
             request_options(context)
           ) do
      if tool.operation["wrap_response"], do: {:ok, %{"result" => result}}, else: {:ok, result}
    end
  end

  defp request_options(context),
    do: for({:deadline, value} <- context, not is_nil(value), do: {:deadline, value})

  def fetch_app_token(config, secret, account) do
    with {:ok, jwt} <- app_jwt(secret),
         installation when is_binary(installation) <-
           (account && account.account_key) || config.public_metadata["installation_id"],
         {:ok, response} <-
           Ankole.Files.HTTP.json(
             "POST",
             base_url(config) <>
               "/app/installations/" <>
               URI.encode(installation, &URI.char_unreserved?/1) <> "/access_tokens",
             headers(jwt),
             %{},
             idempotent: true
           ),
         %{status: status, body: %{"token" => token, "expires_at" => expires_at}}
         when status in 200..299 <- response,
         {:ok, expiry, _} <- DateTime.from_iso8601(expires_at) do
      {:ok, %{access_token: token, expires_in: max(DateTime.diff(expiry, DateTime.utc_now()), 0)}}
    else
      nil -> {:error, :account_required}
      {:error, _} = error -> error
      _ -> {:error, :upstream_token_rejected}
    end
  end

  def refresh_token(config, secret, credentials),
    do:
      token_request(config, secret, %{
        "grant_type" => "refresh_token",
        "refresh_token" => credentials["refresh_token"]
      })

  def oauth_authorize_url(config, secret, params) do
    {kind, params} = Map.pop(params, :subject_kind)
    requested = String.split(params["scope"] || "", ~r/[ ,]+/, trim: true)

    scopes =
      if requested == [] do
        catalog =
          tools()
          |> Enum.filter(&(kind == "app" or &1.annotations["readOnlyHint"] == true))
          |> Enum.flat_map(& &1.scopes)

        Enum.uniq(
          catalog ++ if(kind == "app", do: ["admin:repo_hook", "admin:org_hook"], else: [])
        )
      else
        requested
      end

    query =
      Map.merge(params, %{
        "client_id" => secret["client_id"] || secret["clientID"],
        "response_type" => "code",
        "scope" => scopes |> Enum.uniq() |> Enum.join(" ")
      })

    query =
      if Map.get(config, :auth_scheme) == "github_app",
        do: Map.delete(query, "scope"),
        else: query

    {:ok, web_url(config) <> "/login/oauth/authorize?" <> URI.encode_query(query)}
  end

  def scopes_satisfied?(_required, _granted, %{auth_scheme: "github_app"}), do: true
  def scopes_satisfied?(required, granted, _config), do: Enum.all?(required, &(&1 in granted))

  def oauth_exchange(config, secret, params) do
    with {:ok, tokens} <- token_request(config, secret, params),
         {:ok, response} <-
           Ankole.Files.HTTP.request(
             "GET",
             base_url(config) <> "/user",
             headers(tokens["access_token"]),
             nil,
             idempotent: true
           ),
         {:ok, %{"id" => id}} <- HTTP.decode(response, idempotent: true) do
      tokens = Map.put(tokens, "external_subject_id", to_string(id))

      {:ok,
       if(Map.get(config, :auth_scheme) == "github_app",
         do: Map.put_new(tokens, "scope", []),
         else: tokens
       )}
    end
  end

  def reconcile_trigger(config, _secret, trigger, desired?) do
    with {:ok, account} <- Ankole.Connectors.get_account_by_id(trigger.connected_account_id),
         {:ok, token} <-
           Ankole.Connectors.Credentials.subscription_token(config, account, __MODULE__, desired?) do
      case reconcile_subscription(config, trigger, desired?, token) do
        {:error, %{status: 401} = error} ->
          with {:ok, _token} <-
                 Ankole.Connectors.Credentials.refresh_rejected_token(
                   config,
                   account,
                   token,
                   __MODULE__
                 ) do
            {:error,
             Map.merge(error, %{
               retryable: true,
               message: "The connection was refreshed. Retry this subscription."
             })}
          end

        result ->
          result
      end
    end
  end

  defp reconcile_subscription(config, trigger, desired?, token) do
    with {:ok, path} <- hooks_path(trigger),
         {:ok, hooks} <- list_hooks(config, token, path, 1, []),
         callback <-
           AnkoleWeb.Endpoint.url() <>
             "/webhooks/connectors/#{config.tenant_id}/triggers/#{trigger.id}" do
      existing = Enum.find(hooks, &(get_in(&1, ["config", "url"]) == callback))

      cond do
        desired? and existing ->
          {:ok, %{external_subscription_id: to_string(existing["id"])}}

        desired? ->
          with {:ok, webhook_secret} <-
                 Ankole.Connectors.Credentials.unseal(
                   trigger.sealed_secret,
                   "connector_trigger",
                   trigger.id
                 ),
               body <- %{
                 "name" => "web",
                 "active" => true,
                 "events" => trigger.config["events"] || ["push", "pull_request", "issues"],
                 "config" => %{
                   "url" => callback,
                   "content_type" => "json",
                   "secret" => webhook_secret["webhook_secret"]
                 }
               },
               {:ok, response} <-
                 Ankole.Files.HTTP.request(
                   "POST",
                   base_url(config) <> path,
                   headers(token),
                   Torque.encode!(body)
                 ),
               {:ok, %{"id" => id}} <-
                 decode(response, headers(token), [], [webhook_secret["webhook_secret"]]),
               do: {:ok, %{external_subscription_id: to_string(id)}},
               else: (
                 {:error, _} = error -> error
                 _ -> {:error, :subscription_rejected}
               )

        existing ->
          case Ankole.Files.HTTP.request(
                 "DELETE",
                 base_url(config) <> path <> "/" <> to_string(existing["id"]),
                 headers(token),
                 nil,
                 idempotent: true
               ) do
            {:ok, %{status: status}} when status in [204, 404] ->
              {:ok, %{external_subscription_id: nil}}

            {:error, _} = error ->
              error

            {:ok, response} ->
              decode(response, headers(token), idempotent: true)
          end

        true ->
          {:ok, %{external_subscription_id: nil}}
      end
    end
  end

  defp hooks_path(%{trigger_type: "github_repository", scope_key: key}) do
    case String.split(key, "/") do
      [owner, repo] when owner != "" and repo != "" ->
        {:ok,
         "/repos/" <>
           URI.encode(owner, &URI.char_unreserved?/1) <>
           "/" <> URI.encode(repo, &URI.char_unreserved?/1) <> "/hooks"}

      _ ->
        {:error, :invalid_repository}
    end
  end

  defp hooks_path(%{trigger_type: "github_organization", scope_key: org}),
    do: {:ok, "/orgs/" <> URI.encode(org, &URI.char_unreserved?/1) <> "/hooks"}

  defp hooks_path(_), do: {:error, :unsupported_trigger_type}

  defp list_hooks(config, token, path, page, acc) do
    with {:ok, response} <-
           Ankole.Files.HTTP.request(
             "GET",
             base_url(config) <> path <> "?per_page=100&page=#{page}",
             headers(token),
             nil,
             idempotent: true
           ),
         {:ok, hooks} when is_list(hooks) <- decode(response, headers(token), idempotent: true) do
      if length(hooks) == 100,
        do: list_hooks(config, token, path, page + 1, acc ++ hooks),
        else: {:ok, acc ++ hooks}
    end
  end

  defp decode(response, headers, opts \\ [], extra_secrets \\ []) do
    case HTTP.decode(response, opts) do
      {:error, error} -> {:error, HTTP.redact_credentials(error, headers, extra_secrets)}
      result -> result
    end
  end

  def webhook(config, secret, raw_body, headers) do
    supplied = header(headers, "x-hub-signature-256")
    signing_secret = secret["webhook_secret"] || secret["webhookSecret"]

    with true <- is_binary(signing_secret) and is_binary(supplied),
         expected <-
           "sha256=" <>
             Base.encode16(:crypto.mac(:hmac, :sha256, signing_secret, raw_body), case: :lower),
         true <- Plug.Crypto.secure_compare(expected, supplied),
         {:ok, data} <- Torque.decode(raw_body),
         id when is_binary(id) <- header(headers, "x-github-delivery"),
         event when is_binary(event) <- header(headers, "x-github-event") do
      {:ok,
       %{
         "specversion" => "1.0",
         "id" => id,
         "source" => "connector://#{config.id}/github",
         "type" => "github." <> event,
         "data" => data
       }}
    else
      _ -> {:error, :invalid_webhook_signature}
    end
  end

  defp token_request(config, secret, params) do
    body =
      Map.merge(params, %{
        "client_id" => secret["client_id"] || secret["clientID"],
        "client_secret" => secret["client_secret"] || secret["clientSecret"]
      })

    with {:ok, %{status: status, body: tokens}} when status in 200..299 <-
           Ankole.Files.HTTP.json(
             "POST",
             web_url(config) <> "/login/oauth/access_token",
             [{"accept", "application/json"}, {"content-type", "application/json"}],
             body
           ),
         %{"access_token" => _} <- tokens do
      {:ok, tokens}
    else
      %{"error" => error} when error in ["bad_refresh_token", "invalid_grant"] ->
        {:error, :invalid_grant}

      {:ok, %{body: %{"error" => error}}} when error in ["bad_refresh_token", "invalid_grant"] ->
        {:error, :invalid_grant}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:error, _} = error ->
        error

      _ ->
        {:error, :oauth_token_rejected}
    end
  end

  defp app_jwt(secret) do
    now = System.system_time(:second)

    signing_input =
      encode(%{"alg" => "RS256", "typ" => "JWT"}) <>
        "." <>
        encode(%{
          "iat" => now - 60,
          "exp" => now + 540,
          "iss" => secret["app_id"] || secret["appID"]
        })

    with pem when is_binary(pem) <- secret["private_key"] || secret["privateKey"],
         [entry] <- :public_key.pem_decode(pem) do
      key = :public_key.pem_entry_decode(entry)

      {:ok,
       signing_input <>
         "." <> Base.url_encode64(:public_key.sign(signing_input, :sha256, key), padding: false)}
    else
      _ -> {:error, :invalid_github_private_key}
    end
  rescue
    _ in [ArgumentError, ErlangError, MatchError] -> {:error, :invalid_github_private_key}
  end

  defp encode(value), do: value |> Torque.encode!() |> Base.url_encode64(padding: false)
  defp base_url(config), do: configured_url(config, "base_url", "https://api.github.com")
  def web_url(config), do: configured_url(config, "web_url", website_url(base_url(config)))
  defp website_url("https://api.github.com"), do: "https://github.com"

  defp website_url(base),
    do: URI.to_string(%{URI.parse(base) | path: nil, query: nil, fragment: nil})

  defp uploads_url("https://api.github.com"), do: "https://uploads.github.com"
  defp uploads_url(base), do: website_url(base) <> "/api/uploads"

  defp configured_url(config, key, default) do
    case config.public_metadata[key] do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> default
    end
  end

  defp headers(token), do: [{"content-type", "application/json"} | auth_headers(token)]

  defp auth_headers(token),
    do: [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "Ankole-Connectors"}
    ]

  defp header(headers, name),
    do:
      Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
end
