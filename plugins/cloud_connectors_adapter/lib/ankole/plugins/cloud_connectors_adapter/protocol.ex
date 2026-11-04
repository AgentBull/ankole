defmodule Ankole.Plugins.CloudConnectorsAdapter.Protocol do
  @moduledoc false
  alias Ankole.Connectors.HTTP

  @oauth %{
    "gitlab" =>
      {"https://gitlab.com", "/oauth/authorize", "/oauth/token", ~w(read_user read_api)},
    "typeform" =>
      {"https://api.typeform.com", "/oauth/authorize", "/oauth/token",
       ~w(accounts:read forms:read responses:read offline)},
    "salesforce" =>
      {"https://login.salesforce.com", "/services/oauth2/authorize", "/services/oauth2/token",
       ~w(api refresh_token openid)},
    "trello" =>
      {"https://auth.atlassian.com", "/authorize", "/oauth/token",
       ~w(read:member:trello read:board:trello read:organization:trello offline_access)},
    "calendly" =>
      {"https://auth.calendly.com", "/oauth/authorize", "/oauth/token",
       ~w(users:read scheduled_events:read event_types:read organizations:read availability:read)},
    "googlecalendar" =>
      {"https://accounts.google.com", "/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token",
       ~w(openid email profile https://www.googleapis.com/auth/calendar.readonly)},
    "google_analytics" =>
      {"https://accounts.google.com", "/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token",
       ~w(openid email profile https://www.googleapis.com/auth/analytics.readonly)}
  }

  def platform_application(id, secret) do
    value = secret["clientID"] || secret["client_id"]

    cond do
      id in ~w(figma stripe sentry zendesk) -> {:ok, nil}
      is_binary(value) and value != "" -> {:ok, id <> ":" <> value}
      true -> {:error, :oauth_client_id_required}
    end
  end

  def scopes_satisfied?(id, _required, _granted) when id in ~w(figma stripe sentry zendesk),
    do: true

  def scopes_satisfied?(id, required, granted),
    do: Enum.all?(required, &scope_granted?(id, &1, granted))

  defp scope_granted?("gitlab", scope, granted),
    do:
      scope in granted or
        ("api" in granted and scope in ~w(read_api read_user read_repository write_repository))

  defp scope_granted?("salesforce", "api", granted),
    do: "api" in granted or "full" in granted

  defp scope_granted?("calendly", scope, granted),
    do: scope in granted or String.replace_suffix(scope, ":read", ":write") in granted

  defp scope_granted?(
         "google_analytics",
         "https://www.googleapis.com/auth/analytics.readonly",
         granted
       ),
       do:
         Enum.any?(~w(analytics.readonly analytics.edit analytics), fn scope ->
           ("https://www.googleapis.com/auth/" <> scope) in granted
         end)

  defp scope_granted?(id, "https://www.googleapis.com/auth/calendar" <> suffix = scope, granted)
       when id in ~w(googlecalendar google_analytics) do
    scope in granted or "https://www.googleapis.com/auth/calendar" in granted or
      (suffix in [".events", ".events.readonly"] and
         "https://www.googleapis.com/auth/calendar.events" in granted) or
      (suffix in [
         ".events.readonly",
         ".calendarlist.readonly",
         ".calendars.readonly",
         ".settings.readonly"
       ] and
         "https://www.googleapis.com/auth/calendar.readonly" in granted) or
      (String.ends_with?(suffix, ".readonly") and
         String.replace_suffix(scope, ".readonly", "") in granted)
  end

  defp scope_granted?(_, scope, granted), do: scope in granted

  def authorize(id, config, secret, params) do
    {base, path, _, defaults} = Map.fetch!(@oauth, id)
    requested = String.split(params["scope"] || "", ~r/[ ,]+/, trim: true)
    scopes = Enum.uniq(if(requested == [], do: defaults, else: requested ++ identity_scopes(id)))

    query =
      params
      |> Map.drop([:subject_kind])
      |> Map.merge(%{
        "client_id" => secret["clientID"] || secret["client_id"],
        "response_type" => "code",
        "scope" => Enum.join(scopes, " ")
      })
      |> Map.merge(authorize_options(id))

    {:ok, origin(id, config, base) <> path <> "?" <> URI.encode_query(query)}
  end

  def exchange(id, config, secret, params) do
    with {:ok, tokens} <-
           token_request(
             id,
             config,
             secret,
             params |> Map.delete("scope") |> Map.put("grant_type", "authorization_code")
           ),
         {:ok, identity} <- identity(id, config, tokens) do
      {_, _, _, defaults} = Map.fetch!(@oauth, id)
      requested = String.split(params["scope"] || "", ~r/[ ,]+/, trim: true)
      scopes = if requested == [], do: defaults, else: Enum.uniq(requested ++ identity_scopes(id))
      {:ok, tokens |> Map.merge(identity) |> Map.put_new("scope", Enum.join(scopes, " "))}
    end
  end

  def refresh(id, config, secret, credentials) do
    with {:ok, tokens} <-
           token_request(id, config, secret, %{
             "grant_type" => "refresh_token",
             "refresh_token" => credentials["refresh_token"]
           }) do
      {:ok, Map.merge(credentials, tokens)}
    end
  end

  def validate(id, config, credentials) do
    token = credentials["access_token"] || credentials["api_token"]

    config =
      Map.put(
        config,
        :public_metadata,
        Map.merge(metadata(config), Map.take(credentials, ["base_url"]))
      )

    with true <- is_binary(token) and token != "",
         {:ok, identity} <- identity(id, config, Map.put(credentials, "access_token", token)) do
      {:ok, credentials |> Map.put("access_token", token) |> Map.merge(identity)}
    else
      false -> {:error, :connector_credentials_required}
      error -> error
    end
  end

  def auth_params("figma", _config, credentials),
    do: {:ok, %{"parameters" => [header("X-Figma-Token", credentials["access_token"])]}}

  def auth_params("zendesk", config, credentials) do
    metadata = Map.merge(metadata(config), credentials["public_metadata"] || %{})
    email = credentials["email"] || metadata["email"]
    subdomain = credentials["subdomain"] || metadata["subdomain"]
    token = credentials["api_token"] || credentials["access_token"]

    if is_binary(email) and is_binary(subdomain) and
         Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9-]*$/, subdomain) do
      {:ok,
       %{
         "base_url" => "https://#{subdomain}.zendesk.com",
         "parameters" => [
           header("Authorization", "Basic " <> Base.encode64(email <> "/token:" <> token))
         ]
       }}
    else
      {:error, :zendesk_subdomain_and_email_required}
    end
  end

  def auth_params(id, config, credentials) do
    params = %{
      "parameters" => [header("Authorization", "Bearer " <> credentials["access_token"])]
    }

    base =
      credentials["instance_url"] || get_in(credentials, ["public_metadata", "instance_url"]) ||
        get_in(credentials, ["public_metadata", "base_url"]) ||
        metadata(config)["base_url"]

    base =
      if id == "gitlab" and base, do: String.trim_trailing(base, "/") <> "/api/v4", else: base

    {:ok, if(base, do: Map.put(params, "base_url", base), else: params)}
  end

  def identity(id, config, credentials) do
    with {:ok, auth} <- auth_params(id, config, credentials),
         {:ok, url} <- identity_url(id, config, credentials, auth),
         headers <- Enum.map(auth["parameters"], &{&1["name"], &1["value"]}),
         {:ok, response} <- Ankole.Files.HTTP.request("GET", url, headers, nil, idempotent: true),
         {:ok, body} <- decode(response, headers, [credentials["access_token"]]),
         {:ok, identity} <- profile(id, body) do
      metadata =
        Map.merge(
          identity["public_metadata"],
          Map.merge(
            Map.take(metadata(config), ["base_url"]),
            Map.take(credentials, ~w(instance_url subdomain email))
          )
        )

      {:ok, Map.put(identity, "public_metadata", metadata)}
    end
  end

  defp token_request(id, config, secret, params) do
    {base, _, path, _} = Map.fetch!(@oauth, id)

    url =
      if String.starts_with?(path, "https://"), do: path, else: origin(id, config, base) <> path

    client_id = secret["clientID"] || secret["client_id"]
    client_secret = secret["clientSecret"] || secret["client_secret"]
    body = Map.merge(params, %{"client_id" => client_id, "client_secret" => client_secret})

    {content_type, body} =
      if id == "trello",
        do: {"application/json", Torque.encode!(body)},
        else: {"application/x-www-form-urlencoded", URI.encode_query(body)}

    headers = [{"content-type", content_type}]

    headers =
      if id == "calendly",
        do: [
          {"authorization", "Basic " <> Base.encode64(client_id <> ":" <> client_secret)}
          | headers
        ],
        else: headers

    with {:ok, response} <-
           Ankole.Files.HTTP.request("POST", url, headers, body),
         {:ok, result} <- decode(response, headers, [client_secret]) do
      case result do
        %{"access_token" => _} -> {:ok, result}
        _ -> {:error, :invalid_oauth_response}
      end
    else
      {:error, %{details: %{"error" => "invalid_grant"}}} -> {:error, :invalid_grant}
      error -> error
    end
  end

  defp identity_url("gitlab", config, _, _),
    do: {:ok, origin("gitlab", config, "https://gitlab.com") <> "/api/v4/user"}

  defp identity_url("typeform", _, _, _), do: {:ok, "https://api.typeform.com/me"}
  defp identity_url("calendly", _, _, _), do: {:ok, "https://api.calendly.com/users/me"}
  defp identity_url("trello", _, _, _), do: {:ok, "https://api.trello.com/1/members/me"}

  defp identity_url("salesforce", _, tokens, _),
    do: {:ok, tokens["instance_url"] <> "/services/oauth2/userinfo"}

  defp identity_url(id, _, _, _) when id in ~w(googlecalendar google_analytics),
    do: {:ok, "https://openidconnect.googleapis.com/v1/userinfo"}

  defp identity_url("figma", _, _, _), do: {:ok, "https://api.figma.com/v1/me"}
  defp identity_url("stripe", _, _, _), do: {:ok, "https://api.stripe.com/v1/account"}

  defp identity_url("sentry", config, _, _),
    do: {:ok, origin("sentry", config, "https://sentry.io") <> "/api/0/organizations/"}

  defp identity_url("zendesk", _, _, auth), do: {:ok, auth["base_url"] <> "/api/v2/users/me.json"}

  defp profile("calendly", %{"resource" => resource}), do: profile_record(resource, "uri", "name")
  defp profile("zendesk", %{"user" => resource}), do: profile_record(resource, "id", "name")

  defp profile("sentry", [%{"id" => _} = resource | _]),
    do: profile_record(resource, "id", "name")

  defp profile("sentry", []), do: {:error, :sentry_organization_access_required}
  defp profile("typeform", resource), do: profile_record(resource, "user_id", "alias")
  defp profile("figma", resource), do: profile_record(resource, "id", "handle")
  defp profile("trello", resource), do: profile_record(resource, "id", "fullName")
  defp profile("stripe", resource), do: profile_record(resource, "id", "business_profile")

  defp profile(id, resource) when id in ~w(salesforce googlecalendar google_analytics),
    do: profile_record(resource, "sub", "name")

  defp profile(_, resource), do: profile_record(resource, "id", "name")

  defp profile_record(resource, key, label) do
    case resource[key] do
      nil ->
        {:error, :external_subject_required}

      id ->
        {:ok,
         %{
           "external_subject_id" => to_string(id),
           "public_metadata" => %{"name" => resource[label], "email" => resource["email"]}
         }}
    end
  end

  defp identity_scopes(id) when id in ~w(googlecalendar google_analytics),
    do: ~w(openid email profile)

  defp identity_scopes("typeform"), do: ~w(accounts:read offline)
  defp identity_scopes("calendly"), do: ["users:read"]
  defp identity_scopes("trello"), do: ~w(read:member:trello offline_access)
  defp identity_scopes("salesforce"), do: ~w(openid refresh_token)
  defp identity_scopes(_), do: []

  defp authorize_options(id) when id in ~w(googlecalendar google_analytics),
    do: %{"access_type" => "offline", "prompt" => "consent"}

  defp authorize_options("trello"), do: %{"prompt" => "consent"}
  defp authorize_options(_), do: %{}
  defp header(name, value), do: %{"in" => "header", "name" => name, "value" => value}
  defp metadata(config), do: Map.get(config, :public_metadata) || %{}

  defp origin(id, config, default) when id in ~w(gitlab sentry salesforce),
    do: String.trim_trailing(metadata(config)["base_url"] || default, "/")

  defp origin(_, _, default), do: default

  defp decode(response, headers, extra) do
    case HTTP.decode(response) do
      {:error, error} -> {:error, HTTP.redact_credentials(error, headers, extra)}
      result -> result
    end
  end
end
