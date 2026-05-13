defmodule Feishu.Channel do
  @moduledoc false

  use GenServer

  require Logger

  alias Feishu.{DirectCommand, EventMapper, Source}
  alias FeishuOpenAPI.{CardAction, Event.Dispatcher}

  @event_types [
    "im.message.receive_v1",
    "im.message.updated_v1",
    "im.message.recalled_v1",
    "im.message.reaction.created_v1",
    "im.message.reaction.deleted_v1"
  ]

  defstruct [:source, :ws_pid]

  @spec child_spec(BullX.Gateway.SourceConfig.t()) :: Supervisor.child_spec()
  def child_spec(source) do
    %{
      id: {__MODULE__, source.adapter, source.channel_id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(BullX.Gateway.SourceConfig.t()) :: GenServer.on_start()
  def start_link(source), do: GenServer.start_link(__MODULE__, source)

  @spec handle_card_action_callback(map(), BullX.Gateway.SourceConfig.t()) ::
          {:ok, term()} | {:challenge, String.t()} | {:error, term()}
  def handle_card_action_callback(payload, source_config) when is_map(payload) do
    with {:ok, source} <- Source.normalize(source_config) do
      handler =
        FeishuOpenAPI.CardAction.Handler.new(
          skip_sign_verify: true,
          handler: fn action -> handle_card_action(action, source) end
        )

      case FeishuOpenAPI.CardAction.Handler.dispatch(handler, {:decoded, payload}) do
        {:ok, result} -> result
        other -> other
      end
    end
  end

  @impl true
  def init(source_config) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, ws_pid} <- maybe_start_ws(source) do
      Logger.info("feishu source started",
        adapter: "feishu",
        channel_id: source.channel_id,
        domain: Atom.to_string(source.domain),
        transport: if(ws_pid, do: "websocket", else: "disabled")
      )

      {:ok, %__MODULE__{source: source, ws_pid: ws_pid}}
    else
      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:event, event_type, event}, _from, %__MODULE__{} = state) do
    {:reply, handle_event(event_type, event, state.source), state}
  end

  def handle_call({:card_action, action}, _from, %__MODULE__{} = state) do
    {:reply, handle_card_action(action, state.source), state}
  end

  defp maybe_start_ws(%Source{start_transport?: false}), do: {:ok, nil}

  defp maybe_start_ws(%Source{} = source) do
    server = self()

    FeishuOpenAPI.WS.Client.start_link(
      client: Source.client!(source),
      dispatcher: event_dispatcher(server, source),
      auto_reconnect: true
    )
  end

  defp event_dispatcher(server, %Source{} = source) do
    [client: Source.client!(source)]
    |> Dispatcher.new()
    |> register_event_handlers(server)
  end

  defp register_event_handlers(%Dispatcher{} = dispatcher, server) do
    Enum.reduce(@event_types, dispatcher, fn event_type, acc ->
      Dispatcher.on(acc, event_type, fn type, event ->
        GenServer.call(server, {:event, type, event}, 30_000)
      end)
    end)
  end

  defp handle_event(event_type, event, %Source{} = source) do
    :telemetry.execute(
      [:bullx, :feishu, :event, :received],
      %{count: 1},
      %{channel_id: source.channel_id, event_type: event_type}
    )

    event_type
    |> EventMapper.map_event(event, source)
    |> handle_mapped(source)
  end

  defp handle_card_action(action, %Source{} = source) do
    key = card_action_cache_key(source, action)

    case BullX.Cache.get(key) do
      {:ok, _value} ->
        {:ok, {:ignored, :duplicate_card_action}}

      {:error, :not_found} ->
        result =
          action
          |> EventMapper.map_card_action(source)
          |> handle_mapped(source)

        cache_success(key, result, source.card_action_dedupe_ttl_seconds)
        result

      {:error, reason} ->
        {:error, Feishu.Error.map(reason)}
    end
  end

  defp handle_mapped({:ignore, reason}, _source), do: {:ok, {:ignored, reason}}

  defp handle_mapped({:direct_command, command}, %Source{} = source) do
    cache_message_context(source, command)
    DirectCommand.handle(command, source)
  end

  defp handle_mapped({:ok, %{input: input, account_input: account_input} = mapped}, %Source{} = source) do
    cache_message_context(source, mapped)

    with {:ok, _principal, _identity} <-
           BullX.Principals.match_or_create_human_from_channel(account_input),
         {:ok, :accepted, _signal, _mailbox} <- BullX.Gateway.publish(source.source_config, input) do
      :telemetry.execute(
        [:bullx, :feishu, :publish, :stop],
        %{count: 1},
        %{channel_id: source.channel_id, result: :accepted}
      )

      {:ok, :accepted}
    else
      {:error, :activation_required} ->
        maybe_reply_activation_required(input, source)

      {:error, :principal_disabled} ->
        maybe_reply(input, source, BullX.I18n.t("gateway.feishu.auth.denied"))

      {:error, error} when is_map(error) ->
        {:error, error}

      {:error, reason} ->
        {:error, Feishu.Error.map(reason)}
    end
  end

  defp handle_mapped({:error, error}, _source), do: {:error, error}

  defp cache_success(key, {:ok, result}, ttl_seconds) do
    _result = BullX.Cache.put(key, result, ttl_seconds)
    :ok
  end

  defp cache_success(_key, _result, _ttl_seconds), do: :ok

  defp cache_message_context(%Source{} = source, %{context: context}) when is_map(context) do
    key = message_context_cache_key(source, context.message_id || context.event_id)

    value =
      %{
        "event_id" => context.event_id,
        "event_type" => context.event_type,
        "scope_id" => context.scope_id,
        "chat_id" => context.chat_id,
        "chat_type" => context.chat_type,
        "message_id" => context.message_id
      }
      |> reject_nil_values()

    _result = BullX.Cache.put(key, value, source.message_context_ttl_seconds)
    :ok
  end

  defp cache_message_context(%Source{} = source, %{message_id: message_id} = command)
       when is_binary(message_id) do
    key = message_context_cache_key(source, message_id)

    value =
      %{
        "event_id" => command.event_id,
        "event_type" => "direct_command",
        "scope_id" => command.chat_id,
        "chat_id" => command.chat_id,
        "chat_type" => command.chat_type,
        "message_id" => message_id
      }
      |> reject_nil_values()

    _result = BullX.Cache.put(key, value, source.message_context_ttl_seconds)
    :ok
  end

  defp cache_message_context(_source, _mapped), do: :ok

  defp maybe_reply_activation_required(input, %Source{} = source) do
    chat_type = get_in(input, ["event", "data", "chat_type"])

    case chat_type == "p2p" do
      true -> maybe_reply(input, source, BullX.I18n.t("gateway.feishu.auth.activation_required"))
      false -> {:ok, :activation_required}
    end
  end

  defp maybe_reply(input, %Source{} = source, text) do
    command = %{
      event_id: get_in(input, ["provenance", "event_id"]) || input["occurrence_key"],
      chat_id: input["scope_id"],
      chat_type: get_in(input, ["event", "data", "chat_type"]),
      thread_id: input["thread_id"],
      message_id: get_in(input, ["reply_channel", "reply_to_external_id"])
    }

    DirectCommand.reply_text(command, source, text, "account_gate")
  end

  defp card_action_cache_key(%Source{} = source, %CardAction{} = action) do
    id = action.token || action.open_message_id || inspect(action.action)
    "feishu:#{source.channel_id}:card_action:#{id}"
  end

  defp message_context_cache_key(%Source{} = source, id) when is_binary(id) do
    "feishu:#{source.channel_id}:message_context:#{id}"
  end

  defp message_context_cache_key(%Source{} = source, _id) do
    "feishu:#{source.channel_id}:message_context:unknown"
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
