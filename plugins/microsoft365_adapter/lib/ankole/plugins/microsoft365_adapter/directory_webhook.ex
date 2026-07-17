defmodule Ankole.Plugins.Microsoft365Adapter.DirectoryWebhook do
  @moduledoc """
  Graph change-notification receiver behind
  `/webhooks/v1/entra-id/{provider_id}/directory`.

  Handles the subscription validation handshake (echo `validationToken` as
  text/plain) and basic notifications. Notification authenticity comes from
  the per-subscription `clientState` secret; notifications with a wrong or
  missing clientState are dropped and counted, and the response stays 202 so
  probes learn nothing. Basic notifications carry only ids — the identity
  provider re-fetches authoritative objects before writing.
  """

  alias Ankole.{IdentityProviders, Logging}
  alias Ankole.Plugins.Microsoft365Adapter.{Config, GraphSubscriptions, IdentityProvider}
  alias Ankole.Plugins.MapHelpers

  @spec handle_webhook(map()) :: {:ok, map()} | {:error, term()}
  def handle_webhook(%{kind: "directory"} = request) do
    case MapHelpers.optional_text(request.query_params, "validationToken") do
      token when is_binary(token) ->
        {:ok, %{status: 200, body: token, content_type: "text/plain"}}

      nil ->
        handle_notifications(request)
    end
  end

  def handle_webhook(_request), do: {:ok, %{status: 404, body: %{"error" => "unknown webhook"}}}

  defp handle_notifications(%{instance_id: provider_id} = request) do
    notifications = MapHelpers.fetch_list(request.body_params, "value")

    case provider_config(provider_id) do
      {:ok, config} ->
        consumer = consumer(provider_id, config, request)

        {accepted, dropped} =
          Enum.split_with(notifications, fn notification ->
            GraphSubscriptions.valid_client_state?(
              provider_id,
              MapHelpers.optional_text(notification, "clientState")
            )
          end)

        maybe_log_dropped(provider_id, dropped)

        case process_notifications(accepted, consumer) do
          {:ok, _results} ->
            {:ok, %{status: 202, body: %{}}}

          {:error, reason} ->
            Logging.warning(
              "microsoft365_adapter.directory_webhook.processing_failed",
              "Entra directory notification processing failed",
              %{provider_id: provider_id, reason: inspect(reason)}
            )

            {:ok, %{status: 500, body: %{"error" => "notification processing failed"}}}
        end

      {:error, :unknown_provider} ->
        # Same shape as the dropped-clientState path: nothing to learn here.
        {:ok, %{status: 202, body: %{}}}

      {:error, reason} ->
        Logging.warning(
          "microsoft365_adapter.directory_webhook.config_unavailable",
          "Entra directory notification received without loadable provider config",
          %{provider_id: provider_id, reason: inspect(reason)}
        )

        {:ok, %{status: 500, body: %{"error" => "provider configuration unavailable"}}}
    end
  end

  defp process_notifications(notifications, consumer) do
    notifications
    |> Enum.map(fn notification ->
      case normalize_notification(notification) do
        {:ok, event_type, event} ->
          case IdentityProvider.handle_contact_event(event_type, event, [consumer]) do
            {:ok, results} -> {:ok, results}
            {:error, _reason} = error -> error
          end

        :skip ->
          {:ok, [%{status: :ignored_unrecognized_notification}]}
      end
    end)
    |> MapHelpers.collect_results()
  end

  @doc false
  @spec normalize_notification(map()) :: {:ok, String.t(), map()} | :skip
  def normalize_notification(notification) do
    resource_data = MapHelpers.fetch_map(notification, "resourceData", %{})

    id =
      MapHelpers.optional_text(resource_data, "id") ||
        id_from_resource(MapHelpers.optional_text(notification, "resource"))

    kind =
      resource_kind(
        MapHelpers.optional_text(resource_data, "@odata.type"),
        MapHelpers.optional_text(notification, "resource")
      )

    change_type = MapHelpers.optional_text(notification, "changeType")

    case {id, kind, change_type} do
      {id, kind, change_type}
      when is_binary(id) and kind in ["user", "group"] and change_type in ["updated", "deleted"] ->
        {:ok, "#{kind}.#{change_type}",
         %{"id" => id, "resource_kind" => kind, "change_type" => change_type}}

      _unrecognized ->
        :skip
    end
  end

  defp resource_kind(odata_type, resource) do
    cond do
      is_binary(odata_type) and String.downcase(odata_type) == "#microsoft.graph.user" -> "user"
      is_binary(odata_type) and String.downcase(odata_type) == "#microsoft.graph.group" -> "group"
      is_binary(resource) and String.starts_with?(String.downcase(resource), "users/") -> "user"
      is_binary(resource) and String.starts_with?(String.downcase(resource), "groups/") -> "group"
      true -> nil
    end
  end

  defp id_from_resource(nil), do: nil

  defp id_from_resource(resource) do
    case String.split(resource, "/", parts: 2) do
      [_collection, id] when id != "" -> id
      _other -> nil
    end
  end

  defp consumer(provider_id, config, request) do
    base = IdentityProvider.identity_consumer(provider_id, config)

    case request do
      %{client_opts: client_opts} when is_list(client_opts) ->
        Map.put(base, :client_opts, client_opts)

      _request ->
        base
    end
  end

  defp provider_config(provider_id) do
    with {:ok, providers} <- IdentityProviders.list_active_provider_refs("entra-id"),
         %{"config_key" => config_key} <-
           Enum.find(providers, &(&1["provider_id"] == provider_id)) || :unknown,
         {:ok, config} <- Config.load_identity_config_key(config_key) do
      {:ok, config}
    else
      :unknown -> {:error, :unknown_provider}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_log_dropped(_provider_id, []), do: :ok

  defp maybe_log_dropped(provider_id, dropped) do
    Logging.warning(
      "microsoft365_adapter.directory_webhook.client_state_mismatch",
      "Entra directory notifications dropped for clientState mismatch",
      %{provider_id: provider_id, count: length(dropped)}
    )
  end
end
