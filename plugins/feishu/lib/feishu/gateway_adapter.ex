defmodule Feishu.GatewayAdapter do
  @moduledoc """
  Gateway adapter implementation for Feishu/Lark sources.
  """

  @behaviour BullX.Gateway.Adapter

  alias BullX.Gateway.SourceConfig
  alias Feishu.{Delivery, EventMapper, Source, StreamingCard}
  alias FeishuOpenAPI.{CardAction, Event}

  @impl BullX.Gateway.Adapter
  def config_schema do
    %{
      "credential_id" => %{type: "string", default: "default", secret: false},
      "domain" => %{type: "enum", values: ["feishu", "lark"], default: "feishu"},
      "tenant_key" => %{type: "string", required: false},
      "bot_open_id" => %{type: "string", required: false},
      "oidc" => %{type: "object", required: false}
    }
  end

  @impl BullX.Gateway.Adapter
  def normalize_config(config) when is_map(config) do
    source = %SourceConfig{adapter: "feishu", channel_id: "_validation", config: config}

    case Source.normalize(source) do
      {:ok, source} -> {:ok, Source.public_config(source.source_config)}
      {:error, error} -> {:error, error}
    end
  end

  @impl BullX.Gateway.Adapter
  def public_config(config) when is_map(config), do: Source.public_config(config)

  @impl BullX.Gateway.Adapter
  def capabilities do
    %{
      inbound_modes: [:websocket, :callback],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [:text, :image, :audio, :video, :file, :card],
      stream_strategy: :native
    }
  end

  @impl BullX.Gateway.Adapter
  def connectivity_check(%SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, token} <- FeishuOpenAPI.Auth.tenant_access_token(Source.client!(source)) do
      {:ok,
       %{
         status: :ok,
         adapter: "feishu",
         channel_id: source.channel_id,
         capabilities: [:inbound, :send, :edit, :stream, :cards],
         details: %{
           "domain" => Atom.to_string(source.domain),
           "transport" => "websocket",
           "credential" => "verified",
           "expires_in_seconds" => token.expire
         }
       }}
    else
      {:error, error} -> {:error, connectivity_error(error)}
    end
  end

  def connectivity_check(%{} = source) do
    with {:ok, source} <- SourceConfig.normalize(source) do
      connectivity_check(source)
    end
  end

  @impl BullX.Gateway.Adapter
  def source_child_spec(%SourceConfig{enabled?: false}), do: :ignore
  def source_child_spec(%SourceConfig{} = source), do: Feishu.Channel.child_spec(source)

  @impl BullX.Gateway.Adapter
  def normalize_inbound(%Event{} = event, %SourceConfig{} = source_config, _metadata) do
    with {:ok, source} <- Source.normalize(source_config) do
      EventMapper.normalize_event(event.type, event, source)
    end
  end

  def normalize_inbound(%CardAction{} = action, %SourceConfig{} = source_config, _metadata) do
    with {:ok, source} <- Source.normalize(source_config) do
      EventMapper.normalize_card_action(action, source)
    end
  end

  def normalize_inbound(%{} = payload, %SourceConfig{} = source_config, metadata) do
    case Map.get(metadata, "kind") || Map.get(metadata, :kind) do
      :card_action -> normalize_card_action_payload(payload, source_config)
      "card_action" -> normalize_card_action_payload(payload, source_config)
      _other -> normalize_event_payload(payload, source_config)
    end
  end

  @impl BullX.Gateway.Adapter
  def deliver(delivery, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      Delivery.deliver(delivery, source)
    end
  end

  @impl BullX.Gateway.Adapter
  def stream(delivery, enumerable, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      StreamingCard.stream(delivery, enumerable, source)
    end
  end

  defp normalize_event_payload(payload, source_config) do
    event = Event.from_envelope(payload)
    normalize_inbound(event, source_config, %{})
  end

  defp normalize_card_action_payload(payload, source_config) do
    action = CardAction.from_payload(payload)
    normalize_inbound(action, source_config, %{})
  end

  defp connectivity_error(%{"kind" => kind} = error)
       when kind in ["auth", "config", "network", "rate_limit", "unknown"] do
    error
  end

  defp connectivity_error(%FeishuOpenAPI.Error{} = error), do: Feishu.Error.map(error)
  defp connectivity_error(error), do: Feishu.Error.map(error)
end
