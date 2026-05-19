defmodule Discord.ChannelAdapter do
  @moduledoc """
  EventBus channel adapter for trusted Discord sources.

  The adapter normalizes Discord gateway and interaction occurrences into
  decoded CloudEvents. It does not evaluate Event Routing Rules or persist
  business facts.
  """

  @behaviour BullX.EventBus.ChannelAdapter

  alias BullX.EventBus.ChannelAdapter, as: EventBusAdapter
  alias BullX.Principals.Principal
  alias Discord.{DirectCommand, EventMapper, Source}

  @impl BullX.EventBus.ChannelAdapter
  def normalize_inbound(source_config, provider_input) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      provider_input
      |> EventMapper.map(source)
      |> handle_mapped(source)
    else
      {:error, error} -> {:error, Discord.Error.map(error)}
    end
  end

  @impl BullX.EventBus.ChannelAdapter
  def deliver(source_config, reply_channel, outbound, opts) do
    Discord.Outbound.deliver(source_config, reply_channel, outbound, opts)
  end

  @impl BullX.EventBus.ChannelAdapter
  def consume_stream(source_config, reply_channel, stream_id, opts) do
    Discord.Streamer.consume(source_config, reply_channel, stream_id, opts)
  end

  @impl BullX.EventBus.ChannelAdapter
  def fetch_source(source_id), do: Source.fetch_enabled_source(source_id)

  @impl BullX.EventBus.ChannelAdapter
  def capabilities do
    %{
      inbound_modes: [:discord_gateway_ws, :interaction],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [
        :text,
        :image,
        :audio,
        :video,
        :file,
        :card,
        :control_notice,
        :progress_notice
      ],
      features: [:threads, :application_commands, :ephemeral_provider_responses, :oauth2_login],
      stream_strategy: :edit_accumulate,
      im_listen_modes: Source.im_listen_modes()
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

  defp handle_mapped({:ok, mapped}, %Source{} = source) do
    case BullX.Principals.match_or_create_human_from_channel(mapped.account_input) do
      {:ok, principal, _identity} ->
        mapped.attrs
        |> put_actor_principal(principal)
        |> EventBusAdapter.build_cloud_event()

      {:error, :activation_required} when mapped.command? ->
        EventBusAdapter.build_cloud_event(mapped.attrs)

      {:error, :activation_required} ->
        maybe_reply_activation_required(mapped.attrs, source)
        :ignore

      {:error, :principal_disabled} ->
        maybe_reply(mapped.attrs, source, BullX.I18n.t("eventbus.discord.auth.denied"))
        :ignore

      {:error, error} ->
        {:error, Discord.Error.map(error)}
    end
  end

  defp handle_mapped({:error, error}, _source), do: {:error, Discord.Error.map(error)}

  defp put_actor_principal(attrs, %Principal{id: id, type: type}) do
    put_in(attrs, [:data, :actor, :principal], %{id: id, type: Atom.to_string(type)})
  end

  defp maybe_reply_activation_required(attrs, %Source{} = source) do
    case get_in(attrs, [:data, :routing_facts, "guild_id"]) do
      nil ->
        maybe_reply(attrs, source, BullX.I18n.t("eventbus.discord.auth.activation_required"))

      _guild ->
        maybe_reply(attrs, source, BullX.I18n.t("eventbus.discord.auth.direct_command_dm_only"))
    end
  end

  defp maybe_reply(attrs, %Source{} = source, text) do
    reply_channel = get_in(attrs, [:data, :reply_channel])

    command = %{
      event_id: attrs.id,
      channel_id: map_value(reply_channel, "scope_id"),
      message_id: map_value(reply_channel, "reply_to_external_id")
    }

    _result = DirectCommand.reply_text(command, source, text, "account_gate")
    :ok
  end

  defp map_value(nil, _key), do: nil
  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
