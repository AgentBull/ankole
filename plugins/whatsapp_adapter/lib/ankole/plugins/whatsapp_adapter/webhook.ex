defmodule Ankole.Plugins.WhatsAppAdapter.Webhook do
  @moduledoc """
  Cloud API webhook handler behind `/webhooks/v1/whatsapp/{appId}/events`.

  Meta owns the callback URL at App level, so the instance segment is the Meta
  App ID and one URL serves every phone number of that App. A GET answers the
  subscription verification with the challenge; a POST carries the message
  changes, which the handler routes to the binding of
  `value.metadata.phone_number_id`.

  The handler verifies `x-hub-signature-256` over the exact request bytes before
  it reads the payload, then completes durable ingress for every message before
  it returns 200 (durable-accept-then-ack). Meta retries a delivery that did not
  get a 200 for up to seven days and can also send a duplicate; the gateway's
  `(agent_uid, binding_name, source_event_id)` key absorbs the copy because the
  message id is the source event id.
  """

  alias Ankole.{Logging, SignalsGateway}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.{Config, Inbound, Signature}
  alias Ankole.SignalsGateway.AdapterContext

  @spec handle_webhook(map()) :: {:ok, map()} | {:error, term()}
  def handle_webhook(%{kind: "events", method: "GET", instance_id: app_id} = request) do
    case consumers_for_app(app_id) do
      [] -> {:ok, %{status: 404, body: %{"error" => "unknown app"}}}
      [consumer | _rest] -> verify_subscription(request, consumer, app_id)
    end
  end

  def handle_webhook(%{kind: "events", method: "POST", instance_id: app_id} = request) do
    case consumers_for_app(app_id) do
      [] ->
        {:ok, %{status: 404, body: %{"error" => "unknown app"}}}

      [consumer | _rest] = consumers ->
        signature = Map.get(request.headers, "x-hub-signature-256")

        if Signature.valid?(request.raw_body, signature, Config.app_secret(consumer.config)) do
          dispatch(request.body_params, consumers, app_id)
        else
          Logging.warning(
            "whatsapp_adapter.webhook.unauthorized",
            "WhatsApp webhook signature rejected",
            %{app_id: app_id}
          )

          {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
        end
    end
  end

  def handle_webhook(_request), do: {:ok, %{status: 404, body: %{"error" => "unknown webhook"}}}

  # Meta subscribes the callback URL with a GET and expects the raw challenge
  # back as plain text. Every enabled binding of one App carries the same verify
  # token, so the first one answers for the App.
  defp verify_subscription(request, consumer, app_id) do
    query = request.query_params
    challenge = MapHelpers.presence(query["hub.challenge"])
    token = MapHelpers.presence(query["hub.verify_token"])

    if query["hub.mode"] == "subscribe" and is_binary(challenge) and is_binary(token) and
         Plug.Crypto.secure_compare(token, Config.verify_token(consumer.config)) do
      {:ok, %{status: 200, body: challenge, content_type: "text/plain"}}
    else
      Logging.warning(
        "whatsapp_adapter.webhook.verification_rejected",
        "WhatsApp subscription verification rejected",
        %{app_id: app_id}
      )

      {:ok, %{status: 403, body: %{"error" => "forbidden"}}}
    end
  end

  defp dispatch(%{"entry" => entries}, consumers, app_id) when is_list(entries) do
    entries
    |> Enum.flat_map(&changes/1)
    |> Enum.map(&dispatch_change(&1, consumers))
    |> MapHelpers.collect_results()
    |> case do
      {:ok, _results} ->
        {:ok, %{status: 200, body: %{}}}

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.webhook.dispatch_failed",
          "WhatsApp change dispatch failed",
          %{app_id: app_id, reason: inspect(reason)}
        )

        {:ok, %{status: 500, body: %{"error" => "change processing failed"}}}
    end
  end

  defp dispatch(_body, _consumers, _app_id),
    do: {:ok, %{status: 400, body: %{"error" => "invalid webhook body"}}}

  defp changes(entry) when is_map(entry), do: MapHelpers.fetch_list(entry, "changes")
  defp changes(_entry), do: []

  # One App can serve several phone numbers, and only some of them belong to
  # this installation. A change for an unknown number is ignored with a 200, so
  # one unconfigured number never blocks the others.
  defp dispatch_change(%{"field" => "messages", "value" => value}, consumers)
       when is_map(value) do
    phone_number_id = get_in(value, ["metadata", "phone_number_id"])

    case Enum.find(consumers, &(Config.phone_number_id(&1.config) == phone_number_id)) do
      nil -> {:ok, [%{status: :ignored_unknown_phone_number}]}
      consumer -> dispatch_value(value, consumer)
    end
  end

  defp dispatch_change(_change, _consumers), do: {:ok, [%{status: :ignored_change_field}]}

  defp dispatch_value(value, consumer) do
    with {:ok, status_results} <- Inbound.handle_statuses(value, consumer),
         {:ok, message_results} <- dispatch_messages(value, consumer) do
      {:ok, [status_results | message_results]}
    end
  end

  defp dispatch_messages(value, consumer) do
    value
    |> MapHelpers.fetch_list("messages")
    |> Enum.map(&dispatch_message(&1, value, consumer))
    |> MapHelpers.collect_results()
    |> case do
      {:ok, results} -> {:ok, List.flatten(results)}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_message(%{"type" => "interactive"} = message, value, consumer) do
    Inbound.handle_card_action("interactive", %{"value" => value, "message" => message}, [
      consumer
    ])
  end

  defp dispatch_message(%{"type" => type} = message, value, consumer) do
    Inbound.handle_message_receive(type, %{"value" => value, "message" => message}, [consumer])
  end

  defp dispatch_message(_message, _value, _consumer),
    do: {:ok, [%{status: :ignored_invalid_message}]}

  defp consumers_for_app(app_id) do
    "whatsapp"
    |> SignalsGateway.list_enabled_bindings()
    |> Enum.flat_map(&binding_consumer(&1, app_id))
  end

  defp binding_consumer(binding, app_id) do
    case Config.load_config_ref(binding.config_ref) do
      {:ok, %Config.Runtime{app_id: ^app_id} = config} ->
        context =
          AdapterContext.new(
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: "WhatsApp"
          )

        [Inbound.chat_consumer(context, config)]

      {:ok, _other_app} ->
        []

      :error ->
        []

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.webhook.binding_config_invalid",
          "WhatsApp binding config could not be loaded",
          %{binding_name: binding.name, reason: inspect(reason)}
        )

        []
    end
  end
end
