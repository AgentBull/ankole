defmodule Ankole.Plugins.CloudConnectorsAdapter.Subscriptions do
  @moduledoc false
  alias Ankole.Connectors.HTTP
  alias Ankole.Plugins.CloudConnectorsAdapter.{Protocol, ZendeskWebhooks}

  def reconcile("zendesk", config, credentials, endpoint, desired),
    do: ZendeskWebhooks.reconcile(config, credentials, endpoint, desired)

  def reconcile("sentry", _config, credentials, endpoint, true) do
    case credentials["webhook_secret"] do
      secret when is_binary(secret) and secret != "" ->
        {:ok,
         %{
           "external_subscription_id" => endpoint["callback_url"],
           "signing_secret" => secret,
           "public_metadata" => %{"callback_url" => endpoint["callback_url"]}
         }}

      _ ->
        {:error,
         %{
           code: "sentry_webhook_configuration_required",
           message:
             "Set this callback URL in the Sentry Internal Integration and save its client secret as the connection's webhook signing secret.",
           callback_url: endpoint["callback_url"],
           retryable: false
         }}
    end
  end

  def reconcile("sentry", _, _, _, false), do: {:ok, %{"external_subscription_id" => nil}}

  def reconcile("typeform", config, credentials, endpoint, desired) do
    scope = endpoint["resource_scope"]
    form = scope["form_id"] || scope["scope_key"]

    tag =
      endpoint["external_subscription_id"] ||
        "ankole-" <>
          (endpoint["callback_url"] |> URI.parse() |> Map.fetch!(:path) |> Path.basename())

    path = "/forms/#{segment(form)}/webhooks/#{segment(tag)}"

    body = %{
      "url" => endpoint["callback_url"],
      "enabled" => true,
      "secret" => endpoint["signing_secret"],
      "verify_ssl" => true
    }

    with {:ok, _} <-
           request(
             "typeform",
             config,
             credentials,
             if(desired, do: "PUT", else: "DELETE"),
             path,
             if(desired, do: body)
           ) do
      {:ok, %{"external_subscription_id" => if(desired, do: tag)}}
    end
  end

  def reconcile("gitlab", config, credentials, endpoint, desired) do
    scope = endpoint["resource_scope"]
    path = "/projects/#{segment(scope["project_id"] || scope["scope_key"])}/hooks"

    with {:ok, existing} <- existing_hook("gitlab", config, credentials, endpoint, path) do
      body = %{
        "url" => endpoint["callback_url"],
        "token" => endpoint["signing_secret"],
        "enable_ssl_verification" => true,
        "push_events" => "gitlab.push" in endpoint["event_types"],
        "merge_requests_events" => "gitlab.merge_request.updated" in endpoint["event_types"],
        "issues_events" => "gitlab.issue.updated" in endpoint["event_types"],
        "pipeline_events" => "gitlab.pipeline.completed" in endpoint["event_types"]
      }

      upsert("gitlab", config, credentials, path, existing, body, desired, "PUT")
    end
  end

  def reconcile("stripe", config, credentials, endpoint, desired) do
    with {:ok, existing} <-
           existing_hook("stripe", config, credentials, endpoint, "/webhook_endpoints?limit=100"),
         {:ok, existing} <- recover_stripe_hook(config, credentials, endpoint, existing, desired) do
      body = %{
        "url" => endpoint["callback_url"],
        "enabled_events" =>
          Enum.map(endpoint["event_types"], &String.replace_prefix(&1, "stripe.", ""))
      }

      upsert("stripe", config, credentials, "/webhook_endpoints", existing, body, desired, "POST")
    end
  end

  def reconcile("figma", config, credentials, endpoint, desired) do
    scope = endpoint["resource_scope"]
    context = scope["context"] || "file"
    context_id = scope["context_id"] || scope["scope_key"]

    path =
      "/v2/webhooks?" <> URI.encode_query(%{"context" => context, "context_id" => context_id})

    with {:ok, %{"webhooks" => hooks}} <- request("figma", config, credentials, "GET", path, nil) do
      existing = find(hooks, endpoint, "endpoint")

      event_type =
        %{
          "figma.file.updated" => "FILE_UPDATE",
          "figma.file_comment.created" => "FILE_COMMENT",
          "figma.library.published" => "LIBRARY_PUBLISH"
        }[List.first(endpoint["event_types"])]

      body = %{
        "event_type" => event_type,
        "context" => context,
        "context_id" => context_id,
        "endpoint" => endpoint["callback_url"],
        "passcode" => endpoint["signing_secret"],
        "status" => "ACTIVE",
        "description" => "Ankole"
      }

      upsert("figma", config, credentials, "/v2/webhooks", existing, body, desired, "PUT")
    end
  end

  def reconcile("trello", config, credentials, endpoint, desired) do
    body = %{
      "callbackURL" => endpoint["callback_url"],
      "idModel" =>
        endpoint["resource_scope"]["board_id"] || endpoint["resource_scope"]["scope_key"],
      "description" => "Ankole",
      "active" => true
    }

    with secret when is_binary(secret) <- credentials["application_secret"],
         {:ok, existing} <- existing_hook("trello", config, credentials, endpoint, "/1/webhooks"),
         {:ok, result} <-
           upsert(
             "trello",
             config,
             credentials,
             "/1/webhooks",
             existing,
             body,
             desired,
             "PUT"
           ) do
      {:ok, Map.put(result, "signing_secret", secret)}
    else
      nil -> {:error, :trello_webhook_application_secret_required}
      error -> error
    end
  end

  def reconcile("calendly", config, credentials, endpoint, desired) do
    scope = endpoint["resource_scope"]
    organization = scope["organization"] || scope["scope_key"]
    level = scope["scope"] || "user"

    user =
      if level == "user",
        do: scope["user"] || credentials["owner"] || credentials["external_subject_id"]

    query =
      %{"organization" => organization, "scope" => level} |> maybe_put("user", user)

    with {:ok, existing} <-
           existing_hook(
             "calendly",
             config,
             credentials,
             endpoint,
             "/webhook_subscriptions?" <> URI.encode_query(query)
           ) do
      cond do
        existing && desired ->
          {:ok, %{"external_subscription_id" => existing["uri"]}}

        existing ->
          with {:ok, _} <-
                 request(
                   "calendly",
                   config,
                   credentials,
                   "DELETE",
                   "/webhook_subscriptions/" <> segment(Path.basename(existing["uri"])),
                   nil
                 ),
               do: {:ok, %{"external_subscription_id" => nil}}

        not desired ->
          {:ok, %{"external_subscription_id" => nil}}

        true ->
          body =
            Map.merge(query, %{
              "url" => endpoint["callback_url"],
              "events" => ~w(invitee.created invitee.canceled),
              "signing_key" => endpoint["signing_secret"]
            })

          with {:ok, %{"resource" => resource}} <-
                 request("calendly", config, credentials, "POST", "/webhook_subscriptions", body),
               do: {:ok, %{"external_subscription_id" => resource["uri"]}}
      end
    end
  end

  defp recover_stripe_hook(
         config,
         credentials,
         %{"external_subscription_id" => nil},
         %{"id" => id},
         true
       ) do
    with {:ok, _} <-
           request(
             "stripe",
             config,
             credentials,
             "DELETE",
             "/webhook_endpoints/" <> segment(id),
             nil
           ),
         do: {:ok, nil}
  end

  defp recover_stripe_hook(_config, _credentials, _endpoint, existing, _desired),
    do: {:ok, existing}

  defp existing_hook(
         "trello",
         _config,
         _credentials,
         %{"external_subscription_id" => nil},
         _path
       ),
       do: {:ok, nil}

  defp existing_hook(id, config, credentials, endpoint, path) do
    case endpoint["external_subscription_id"] do
      nil ->
        with {:ok, result} <- request(id, config, credentials, "GET", path, nil) do
          hooks =
            case id do
              "gitlab" -> result
              "stripe" -> result["data"]
              "calendly" -> result["collection"]
            end

          {:ok, find(hooks, endpoint, if(id == "calendly", do: "callback_url", else: "url"))}
        end

      external_id ->
        path = URI.parse(path).path <> "/" <> segment(Path.basename(external_id))

        case request(id, config, credentials, "GET", path, nil) do
          {:ok, result} -> {:ok, if(id == "calendly", do: result["resource"], else: result)}
          {:error, %{status: 404}} -> {:ok, nil}
          error -> error
        end
    end
  end

  defp upsert(_id, _config, _credentials, _path, nil, _body, false, _method),
    do: {:ok, %{"external_subscription_id" => nil}}

  defp upsert(id, config, credentials, path, existing, _body, false, _method) do
    with {:ok, _} <-
           request(id, config, credentials, "DELETE", path <> "/" <> segment(existing["id"]), nil),
         do: {:ok, %{"external_subscription_id" => nil}}
  end

  defp upsert(id, config, credentials, path, existing, body, true, method) do
    path = if existing, do: path <> "/" <> segment(existing["id"]), else: path

    with {:ok, result} <-
           request(id, config, credentials, if(existing, do: method, else: "POST"), path, body) do
      result = %{
        "external_subscription_id" => to_string(result["id"] || existing["id"]),
        "signing_secret" => result["secret"]
      }

      {:ok, result}
    end
  end

  def request(id, config, credentials, method, path, body) do
    with {:ok, auth} <- Protocol.auth_params(id, config, credentials) do
      base = auth["base_url"] || base_url(id)
      headers = Enum.map(auth["parameters"], &{&1["name"], &1["value"]})
      {content_type, encoded} = encode(id, body)
      headers = [{"content-type", content_type} | headers]

      with {:ok, response} <-
             Ankole.Files.HTTP.request(method, base <> path, headers, encoded,
               idempotent: method in ~w(GET PUT DELETE)
             ) do
        if method == "DELETE" and response.status == 404 do
          {:ok, %{}}
        else
          case HTTP.decode(response, idempotent: method in ~w(GET PUT DELETE)) do
            {:error, error} ->
              {:error, HTTP.redact_credentials(error, headers, [credentials["access_token"]])}

            result ->
              result
          end
        end
      end
    end
  end

  defp find(hooks, endpoint, key),
    do:
      Enum.find(
        hooks,
        &(to_string(&1["id"]) == endpoint["external_subscription_id"] or
            &1[key] == endpoint["callback_url"])
      )

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp encode(_, nil), do: {"application/json", nil}

  defp encode("stripe", body),
    do:
      {"application/x-www-form-urlencoded",
       body
       |> Enum.flat_map(fn
         {key, values} when is_list(values) -> Enum.map(values, &{key <> "[]", &1})
         pair -> [pair]
       end)
       |> URI.encode_query()}

  defp encode(_, body), do: {"application/json", Torque.encode!(body)}
  defp base_url("gitlab"), do: "https://gitlab.com/api/v4"
  defp base_url("typeform"), do: "https://api.typeform.com"
  defp base_url("stripe"), do: "https://api.stripe.com/v1"
  defp base_url("figma"), do: "https://api.figma.com"
  defp base_url("trello"), do: "https://api.trello.com"
  defp base_url("calendly"), do: "https://api.calendly.com"
end
