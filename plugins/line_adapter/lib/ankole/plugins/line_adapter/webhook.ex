defmodule Ankole.Plugins.LineAdapter.Webhook do
  @moduledoc """
  Messaging API webhook handler behind `/webhooks/v1/line/{channelId}/events`.

  One URL serves one LINE channel. The handler verifies the `x-line-signature`
  HMAC over the exact request bytes with that channel's secret before it reads
  the payload, then completes durable ingress for every event before it returns
  200 (durable-accept-then-ack). LINE redelivers a batch that did not get 2xx
  when redelivery is enabled; the gateway's
  `(agent_uid, binding_name, source_event_id)` key absorbs the copy because
  `webhookEventId` is the source event id.
  """

  alias Ankole.{Logging, SignalsGateway}
  alias Ankole.Plugins.LineAdapter.{Config, Inbound, Signature}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.AdapterContext

  @spec handle_webhook(map()) :: {:ok, map()} | {:error, term()}
  def handle_webhook(%{kind: "events", instance_id: channel_id} = request) do
    case consumer_for_channel(channel_id) do
      {:ok, consumer} ->
        signature = Map.get(request.headers, "x-line-signature")

        if Signature.valid?(request.raw_body, signature, Config.channel_secret(consumer.config)) do
          dispatch(request.body_params, consumer, channel_id)
        else
          Logging.warning(
            "line_adapter.webhook.unauthorized",
            "LINE webhook signature rejected",
            %{channel_id: channel_id}
          )

          {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
        end

      :error ->
        {:ok, %{status: 404, body: %{"error" => "unknown channel"}}}
    end
  end

  def handle_webhook(_request), do: {:ok, %{status: 404, body: %{"error" => "unknown webhook"}}}

  # The Verify button in the LINE Developers Console posts an empty event list,
  # so an empty batch is a success.
  defp dispatch(%{"destination" => destination, "events" => events}, consumer, channel_id)
       when is_binary(destination) and is_list(events) do
    events
    |> Enum.map(&dispatch_event(&1, destination, consumer))
    |> MapHelpers.collect_results()
    |> case do
      {:ok, _results} ->
        {:ok, %{status: 200, body: %{}}}

      {:error, reason} ->
        Logging.warning(
          "line_adapter.webhook.dispatch_failed",
          "LINE event dispatch failed",
          %{channel_id: channel_id, reason: inspect(reason)}
        )

        {:ok, %{status: 500, body: %{"error" => "event processing failed"}}}
    end
  end

  defp dispatch(_body, _consumer, _channel_id),
    do: {:ok, %{status: 400, body: %{"error" => "invalid webhook body"}}}

  defp dispatch_event(%{"type" => type} = event, destination, consumer) when is_binary(type) do
    envelope = %{"destination" => destination, "event" => event}

    case type do
      "message" -> Inbound.handle_message_receive(type, envelope, [consumer])
      "unsend" -> Inbound.handle_message_removed(type, envelope, [consumer])
      "postback" -> Inbound.handle_card_action(type, envelope, [consumer])
      _other -> {:ok, [%{status: :ignored_event_type}]}
    end
  end

  defp dispatch_event(_event, _destination, _consumer),
    do: {:ok, [%{status: :ignored_invalid_event}]}

  defp consumer_for_channel(channel_id) do
    "line"
    |> SignalsGateway.list_enabled_bindings()
    |> Enum.find_value(:error, &binding_consumer(&1, channel_id))
  end

  defp binding_consumer(binding, channel_id) do
    case Config.load_config_ref(binding.config_ref) do
      {:ok, %Config.Runtime{channel_id: ^channel_id} = config} ->
        context =
          AdapterContext.new(
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: "LINE"
          )

        {:ok, Inbound.chat_consumer(context, config)}

      {:ok, _other_channel} ->
        nil

      :error ->
        nil

      {:error, reason} ->
        Logging.warning(
          "line_adapter.webhook.binding_config_invalid",
          "LINE binding config could not be loaded",
          %{binding_name: binding.name, reason: inspect(reason)}
        )

        nil
    end
  end
end
