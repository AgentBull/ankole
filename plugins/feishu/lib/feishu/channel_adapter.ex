defmodule Feishu.ChannelAdapter do
  @moduledoc """
  EventBus channel adapter for trusted Feishu/Lark sources.

  The adapter normalizes provider input into decoded CloudEvents and performs
  only the Principal activation gate required before Event acceptance. It does
  not route Events, create TargetSessions, or persist business facts.
  """

  @behaviour BullX.EventBus.ChannelAdapter

  alias BullX.EventBus.ChannelAdapter, as: EventBusAdapter
  alias Feishu.{DirectCommand, EventMapper, Source}

  @impl BullX.EventBus.ChannelAdapter
  def normalize_inbound(source_config, provider_input) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      provider_input
      |> EventMapper.map(source)
      |> handle_mapped(source)
    else
      {:error, error} -> {:error, Feishu.Error.map(error)}
    end
  end

  @impl BullX.EventBus.ChannelAdapter
  def deliver(source_config, reply_channel, outbound, opts) do
    Feishu.Outbound.deliver(source_config, reply_channel, outbound, opts)
  end

  @impl BullX.EventBus.ChannelAdapter
  def consume_stream(source_config, reply_channel, stream_id, opts) do
    Feishu.StreamingCard.consume(source_config, reply_channel, stream_id, opts)
  end

  @impl BullX.EventBus.ChannelAdapter
  def fetch_source(source_id), do: Source.fetch_enabled_source(source_id)

  @impl BullX.EventBus.ChannelAdapter
  def capabilities do
    %{
      inbound_modes: [:websocket, :card_action_callback],
      outbound_ops: [:send, :edit, :stream],
      stream_strategy: :native_cardkit,
      content_kinds: [:text, :image, :audio, :video, :file, :card],
      identity_evidence: [:channel_actor, :oidc_login_subject]
    }
  end

  @spec connectivity_check(map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source_config), do: Source.connectivity_check(source_config)

  defp handle_mapped({:ignore, _reason}, _source), do: :ignore

  defp handle_mapped({:direct_command, command}, %Source{} = source) do
    case DirectCommand.handle(source, command) do
      {:ok, _result} -> :ignore
      {:error, error} -> {:error, error}
    end
  end

  defp handle_mapped({:ok, %{attrs: attrs, account_input: account_input}}, %Source{} = source) do
    case BullX.Principals.match_or_create_human_from_channel(account_input) do
      {:ok, principal, _identity} ->
        attrs
        |> put_principal_ref(principal.id)
        |> EventBusAdapter.build_cloud_event()

      {:error, :activation_required} ->
        maybe_reply_activation_required(attrs, source)
        :ignore

      {:error, :principal_disabled} ->
        maybe_reply(attrs, source, BullX.I18n.t("eventbus.feishu.auth.denied"))
        :ignore

      {:error, error} ->
        {:error, Feishu.Error.map(error)}
    end
  end

  defp handle_mapped({:error, error}, _source), do: {:error, Feishu.Error.map(error)}

  defp put_principal_ref(attrs, principal_id) do
    put_in(attrs, [:data, :actor, :principal_ref], principal_id)
  end

  defp maybe_reply_activation_required(attrs, %Source{} = source) do
    chat_type = get_in(attrs, [:data, :routing_facts, "chat_type"])

    case chat_type == "p2p" do
      true ->
        maybe_reply(attrs, source, BullX.I18n.t("eventbus.feishu.auth.activation_required"))

      false ->
        maybe_reply(attrs, source, BullX.I18n.t("eventbus.feishu.auth.direct_command_dm_only"))
    end
  end

  defp maybe_reply(attrs, %Source{} = source, text) do
    reply_channel = get_in(attrs, [:data, :reply_channel])

    command = %{
      event_id: attrs.id,
      chat_id: map_value(reply_channel, "scope_id"),
      thread_id: map_value(reply_channel, "thread_id"),
      message_id: map_value(reply_channel, "reply_to_external_id")
    }

    _result = DirectCommand.reply_text(command, source, text, "account_gate")
    :ok
  end

  defp map_value(nil, _key), do: nil
  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
