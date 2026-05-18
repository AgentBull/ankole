defmodule Discord.Channel do
  @moduledoc false

  use GenServer

  require Logger

  alias Discord.Source

  defstruct [:source, ready?: false]

  @registry Discord.Registry

  @spec child_spec(Source.t()) :: Supervisor.child_spec()
  def child_spec(%Source{} = source) do
    %{
      id: {__MODULE__, source.id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Source.t()) :: GenServer.on_start()
  def start_link(%Source{} = source), do: GenServer.start_link(__MODULE__, source, name: via(source.id))

  @spec handle_event(Source.t() | String.t(), term(), timeout()) :: term()
  def handle_event(target, event, timeout \\ 30_000)
  def handle_event(%Source{id: id}, event, timeout), do: GenServer.call(via(id), {:event, event}, timeout)
  def handle_event(source_id, event, timeout) when is_binary(source_id), do: GenServer.call(via(source_id), {:event, event}, timeout)

  @spec dispatch_by_bot_name(atom(), term()) :: term()
  def dispatch_by_bot_name(bot_name, event) when is_atom(bot_name) do
    case Registry.lookup(@registry, {:bot, bot_name}) do
      [{pid, _value}] -> GenServer.call(pid, {:event, event}, 30_000)
      [] -> :ok
    end
  end

  defp via(id), do: {:via, Registry, {@registry, {:channel, id}}}

  @impl true
  def init(%Source{} = source) do
    Logger.info("discord source start", source_id: source.id, transport: "gateway")
    _result = Registry.register(@registry, {:bot, Source.bot_name(source)}, source.id)
    {:ok, %__MODULE__{source: source}}
  end

  @impl true
  def handle_call({:event, event}, _from, state) do
    {reply, state} = dispatch(event, state)
    {:reply, reply, state}
  end

  def handle_call(:source, _from, state), do: {:reply, state.source, state}

  defp dispatch({:READY, ready, _ws_state}, state), do: ready(ready, state)
  defp dispatch({:MESSAGE_CREATE, payload, _ws_state}, state), do: accept("message_create", payload, state)
  defp dispatch({:MESSAGE_UPDATE, payload, _ws_state}, state), do: accept("message_update", payload, state)
  defp dispatch({:INTERACTION_CREATE, payload, _ws_state}, state), do: accept("interaction_create", payload, state)
  defp dispatch(_event, state), do: {{:ok, %{status: :ignored, reason: :unsupported_event}}, state}

  defp ready(ready, state) do
    bot_user_id = ready |> field(:user) |> field(:id) |> stringify_id()
    source = if bot_user_id, do: %{state.source | bot_user_id: bot_user_id}, else: state.source
    :telemetry.execute([:bullx, :event_bus, :adapter, :discord, :ready], %{count: 1}, %{source_id: source.id})
    {{:ok, %{status: :ready}}, %{state | source: source, ready?: true}}
  end

  defp accept(event_type, payload, state) do
    result =
      BullX.EventBus.ChannelAdapter.accept_inbound(
        "discord",
        state.source,
        {event_type, stringify_payload(payload)}
      )

    {result, state}
  end

  defp stringify_payload(%{} = payload) do
    Map.new(payload, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_payload(value)}
      {key, value} when is_binary(key) -> {key, stringify_payload(value)}
    end)
  end

  defp stringify_payload(values) when is_list(values), do: Enum.map(values, &stringify_payload/1)
  defp stringify_payload(value), do: value
  defp field(%{} = map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_value, _key), do: nil
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
end
