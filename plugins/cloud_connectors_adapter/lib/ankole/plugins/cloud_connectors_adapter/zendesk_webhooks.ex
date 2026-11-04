defmodule Ankole.Plugins.CloudConnectorsAdapter.ZendeskWebhooks do
  @moduledoc false
  alias Ankole.Plugins.CloudConnectorsAdapter.Subscriptions

  def reconcile(config, credentials, endpoint, desired) do
    with {:ok, hooks} <- hooks(config, credentials, "/api/v2/webhooks", []),
         existing <- Enum.find(hooks, &(&1["endpoint"] == endpoint["callback_url"])) do
      cond do
        desired -> connect(config, credentials, endpoint, existing)
        existing -> disconnect(config, credentials, existing)
        true -> {:ok, %{"external_subscription_id" => nil}}
      end
    end
  end

  defp connect(config, credentials, endpoint, existing) do
    with {:ok, hook} <- ensure_hook(config, credentials, endpoint, existing),
         {:ok, rules} <- rules(config, credentials, "/api/v2/triggers.json", []),
         :ok <- reconcile_rules(config, credentials, hook, endpoint["event_types"], rules),
         {:ok, %{"signing_secret" => %{"secret" => secret}}} <-
           request(
             config,
             credentials,
             "GET",
             "/api/v2/webhooks/#{hook["id"]}/signing_secret",
             nil
           ) do
      {:ok, %{"external_subscription_id" => hook["id"], "signing_secret" => secret}}
    end
  end

  defp ensure_hook(_, _, _, existing) when is_map(existing), do: {:ok, existing}

  defp ensure_hook(config, credentials, endpoint, nil) do
    body = %{
      "webhook" => %{
        "name" => "Ankole",
        "status" => "active",
        "endpoint" => endpoint["callback_url"],
        "http_method" => "POST",
        "request_format" => "json",
        "subscriptions" => ["conditional_ticket_events"]
      }
    }

    with {:ok, %{"webhook" => hook}} <-
           request(config, credentials, "POST", "/api/v2/webhooks", body),
         do: {:ok, hook}
  end

  defp reconcile_rules(config, credentials, hook, event_types, rules) do
    Enum.reduce_while(~w(zendesk.ticket.created zendesk.ticket.updated), :ok, fn type, :ok ->
      existing = Enum.find(rules, &(&1["title"] == title(hook, type)))

      result =
        cond do
          type in event_types ->
            body = %{
              "trigger" => %{
                "title" => title(hook, type),
                "active" => true,
                "conditions" => %{
                  "all" => [
                    %{
                      "field" => "update_type",
                      "value" =>
                        if(type == "zendesk.ticket.created", do: "Create", else: "Change")
                    }
                  ],
                  "any" => []
                },
                "actions" => [
                  %{"field" => "notification_webhook", "value" => [hook["id"], payload(type)]}
                ]
              }
            }

            path =
              if existing,
                do: "/api/v2/triggers/#{existing["id"]}.json",
                else: "/api/v2/triggers.json"

            request(config, credentials, if(existing, do: "PUT", else: "POST"), path, body)

          existing ->
            request(config, credentials, "DELETE", "/api/v2/triggers/#{existing["id"]}.json", nil)

          true ->
            {:ok, %{}}
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp disconnect(config, credentials, hook) do
    with {:ok, rules} <- rules(config, credentials, "/api/v2/triggers.json", []),
         :ok <- reconcile_rules(config, credentials, hook, [], rules),
         {:ok, _} <- request(config, credentials, "DELETE", "/api/v2/webhooks/#{hook["id"]}", nil),
         do: {:ok, %{"external_subscription_id" => nil}}
  end

  defp hooks(config, credentials, path, acc) do
    with {:ok, result} <- request(config, credentials, "GET", path, nil) do
      acc = acc ++ result["webhooks"]

      if get_in(result, ["meta", "has_more"]),
        do: hooks(config, credentials, local_path(result["links"]["next"]), acc),
        else: {:ok, acc}
    end
  end

  defp rules(config, credentials, path, acc) do
    with {:ok, result} <- request(config, credentials, "GET", path, nil) do
      acc = acc ++ result["triggers"]

      if result["next_page"],
        do: rules(config, credentials, local_path(result["next_page"]), acc),
        else: {:ok, acc}
    end
  end

  defp local_path(url) do
    uri = URI.parse(url)
    uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
  end

  defp title(hook, type), do: "Ankole #{hook["id"]} #{type}"

  defp payload(type),
    do:
      Torque.encode!(%{
        "event_type" => type,
        "ticket" => %{
          "id" => "{{ticket.id}}",
          "status" => "{{ticket.status}}",
          "url" => "{{ticket.url}}",
          "updated_at" => "{{ticket.updated_at_with_timestamp}}"
        }
      })

  defp request(config, credentials, method, path, body),
    do: Subscriptions.request("zendesk", config, credentials, method, path, body)
end
