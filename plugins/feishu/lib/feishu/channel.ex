defmodule Feishu.Channel do
  @moduledoc false

  use GenServer

  require Logger

  alias Feishu.Source
  alias FeishuOpenAPI.Event.Dispatcher

  @event_types [
    "im.message.receive_v1",
    "im.message.updated_v1",
    "im.message.recalled_v1",
    "im.message.reaction.created_v1",
    "im.message.reaction.deleted_v1"
  ]

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

  def handle_call({:card_action, action}, _from, %__MODULE__{} = state) do
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
    Enum.reduce(@event_types, dispatcher, fn event_type, acc ->
      Dispatcher.on(acc, event_type, fn type, event ->
        GenServer.call(server, {:event, type, event}, 30_000)
      end)
    end)
  end

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
