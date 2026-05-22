defmodule Feishu.Channel do
  @moduledoc false

  use GenServer

  require Logger

  alias Feishu.Source
  alias FeishuOpenAPI.{CardAction, Event}
  alias FeishuOpenAPI.Event.Dispatcher

  @event_types [
    "im.message.receive_v1",
    "im.message.updated_v1",
    "im.message.recalled_v1",
    "im.message.reaction.created_v1",
    "im.message.reaction.deleted_v1"
  ]
  @card_action_types ["card.action.trigger"]

  defstruct [:source, :ws_pid]

  @spec child_spec(Source.t() | map()) :: Supervisor.child_spec()
  def child_spec(source) do
    id =
      case source do
        %Source{id: id} -> id
        %{"id" => id} -> id
        %{id: id} -> id
        _source -> BullX.Ext.gen_uuid_v7()
      end

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Source.t() | map()) :: GenServer.on_start()
  def start_link(source), do: GenServer.start_link(__MODULE__, source)

  @impl true
  def init(source_config) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, ws_pid} <- maybe_start_ws(source) do
      Logger.info("feishu source started",
        adapter: "feishu",
        source_id: source.id,
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
    {:reply, accept({:event, event_type, event}, state.source), state}
  end

  def handle_call({:card_action, %CardAction{} = action}, _from, %__MODULE__{} = state) do
    {:reply, accept({:card_action, action}, state.source), state}
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
    dispatcher
    |> register_message_event_handlers(server)
    |> register_card_action_handlers(server)
  end

  defp register_message_event_handlers(%Dispatcher{} = dispatcher, server) do
    Enum.reduce(@event_types, dispatcher, fn event_type, acc ->
      Dispatcher.on(acc, event_type, fn type, event ->
        GenServer.call(server, {:event, type, event}, 30_000)
      end)
    end)
  end

  defp register_card_action_handlers(%Dispatcher{} = dispatcher, server) do
    Enum.reduce(@card_action_types, dispatcher, fn callback_type, acc ->
      Dispatcher.on_callback(acc, callback_type, fn _type, event ->
        GenServer.call(server, {:card_action, card_action_from_event(event)}, 30_000)
      end)
    end)
  end

  defp card_action_from_event(%Event{} = event) do
    event
    |> card_action_payload()
    |> CardAction.from_payload()
  end

  defp card_action_payload(%Event{content: %{} = content, raw: raw}) do
    case card_action_payload?(content) do
      true -> content
      false -> raw
    end
  end

  defp card_action_payload(%Event{raw: raw}), do: raw

  defp card_action_payload?(%{"action" => action}) when is_map(action), do: true
  defp card_action_payload?(_payload), do: false

  defp accept(provider_input, %Source{} = source) do
    :telemetry.execute(
      [:bullx, :event_bus, :adapter, :event, :received],
      %{count: 1},
      %{adapter_id: "feishu", source_id: source.id}
    )

    BullX.EventBus.ChannelAdapter.accept_inbound(
      "feishu",
      source,
      provider_input
    )
  end
end
