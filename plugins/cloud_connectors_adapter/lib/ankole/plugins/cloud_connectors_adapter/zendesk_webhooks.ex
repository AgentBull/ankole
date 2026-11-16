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
    with {:ok, hook} <- ensure_hook(config, credentials, endpoint, existing) do
      case finish_connect(config, credentials, hook, endpoint["event_types"]) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason, created_rule_ids} ->
          rollback_connect(config, credentials, hook, existing == nil, created_rule_ids)
          {:error, reason}
      end
    end
  end

  defp finish_connect(config, credentials, hook, event_types) do
    with {:ok, rules} <- wrap_step(rules(config, credentials, "/api/v2/triggers.json", []), []),
         {:ok, created_rule_ids} <- reconcile_rules(config, credentials, hook, event_types, rules),
         {:ok, %{"signing_secret" => %{"secret" => secret}}} <-
           wrap_step(
             request(
               config,
               credentials,
               "GET",
               "/api/v2/webhooks/#{hook["id"]}/signing_secret",
               nil
             ),
             created_rule_ids
           ) do
      {:ok, %{"external_subscription_id" => hook["id"], "signing_secret" => secret}}
    else
      {:ok, _unexpected} ->
        {:error, :invalid_upstream_response, []}

      {:error, _reason, _created_rule_ids} = error ->
        error
    end
  end

  defp wrap_step({:ok, value}, _created_rule_ids), do: {:ok, value}
  defp wrap_step({:error, reason}, created_rule_ids), do: {:error, reason, created_rule_ids}

  defp rollback_connect(config, credentials, hook, created_hook?, created_rule_ids) do
    Enum.each(created_rule_ids, fn id ->
      _ = request(config, credentials, "DELETE", "/api/v2/triggers/#{id}.json", nil)
    end)

    if created_hook? and is_binary(hook["id"]) do
      _ = request(config, credentials, "DELETE", "/api/v2/webhooks/#{hook["id"]}", nil)
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

    with {:ok, %{"webhook" => hook}} when is_map(hook) <-
           request(config, credentials, "POST", "/api/v2/webhooks", body) do
      {:ok, hook}
    else
      {:ok, _unexpected} -> {:error, :invalid_upstream_response}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_rules(config, credentials, hook, event_types, rules) do
    Enum.reduce_while(
      ~w(zendesk.ticket.created zendesk.ticket.updated),
      {:ok, []},
      fn type, {:ok, created_ids} ->
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
              request(
                config,
                credentials,
                "DELETE",
                "/api/v2/triggers/#{existing["id"]}.json",
                nil
              )

            true ->
              {:ok, %{}}
          end

        case result do
          {:ok, %{"trigger" => %{"id" => id}}} when is_nil(existing) and not is_nil(id) ->
            {:cont, {:ok, [id | created_ids]}}

          {:ok, _} ->
            {:cont, {:ok, created_ids}}

          {:error, reason} ->
            {:halt, {:error, reason, created_ids}}
        end
      end
    )
  end

  defp disconnect(config, credentials, %{"id" => hook_id} = hook)
       when is_binary(hook_id) and hook_id != "" do
    with {:ok, rules} <- rules(config, credentials, "/api/v2/triggers.json", []),
         {:ok, _} <- reconcile_rules(config, credentials, hook, [], rules),
         {:ok, _} <- request(config, credentials, "DELETE", "/api/v2/webhooks/#{hook_id}", nil) do
      {:ok, %{"external_subscription_id" => nil}}
    else
      {:error, reason, _created_ids} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp disconnect(_config, _credentials, _hook), do: {:error, :invalid_upstream_response}

  defp hooks(config, credentials, path, acc) do
    case request(config, credentials, "GET", path, nil) do
      {:ok, %{"webhooks" => webhooks} = result} when is_list(webhooks) ->
        acc = acc ++ webhooks

        if get_in(result, ["meta", "has_more"]) == true do
          with {:ok, next_path} <- local_path(get_in(result, ["links", "next"])) do
            hooks(config, credentials, next_path, acc)
          end
        else
          {:ok, acc}
        end

      {:ok, _unexpected} ->
        {:error, :invalid_upstream_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp rules(config, credentials, path, acc) do
    case request(config, credentials, "GET", path, nil) do
      {:ok, %{"triggers" => triggers} = result} when is_list(triggers) ->
        acc = acc ++ triggers

        if result["next_page"] do
          with {:ok, next_path} <- local_path(result["next_page"]) do
            rules(config, credentials, next_path, acc)
          end
        else
          {:ok, acc}
        end

      {:ok, _unexpected} ->
        {:error, :invalid_upstream_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp local_path(url) when is_binary(url) do
    uri = URI.parse(url)

    if is_binary(uri.path) and uri.path != "" do
      {:ok, uri.path <> if(uri.query, do: "?" <> uri.query, else: "")}
    else
      {:error, :invalid_upstream_response}
    end
  end

  defp local_path(_url), do: {:error, :invalid_upstream_response}

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
