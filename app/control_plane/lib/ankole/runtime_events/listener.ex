defmodule Ankole.RuntimeEvents.Listener do
  @moduledoc false

  use GenServer

  alias Ankole.JSON
  alias Ankole.Logging
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Scheduler

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      notifications: Keyword.get(opts, :notifications, Ankole.RuntimeEvents.Notifications),
      scheduler: Keyword.get(opts, :scheduler, Scheduler),
      refs: %{}
    }

    {:ok, state, {:continue, :listen_and_snapshot}}
  end

  @impl true
  def handle_continue(:listen_and_snapshot, state) do
    refs =
      RuntimeEvents.channels()
      |> Map.new(fn channel ->
        {:ok, ref} = Postgrex.Notifications.listen(state.notifications, channel)
        {ref, channel}
      end)

    Scheduler.hydrate(state.scheduler)
    {:noreply, %{state | refs: refs}}
  end

  @impl true
  def handle_info({:notification, _pid, ref, channel, payload}, state) do
    channel = Map.get(state.refs, ref, channel)

    case JSON.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        Scheduler.notify(state.scheduler, channel, decoded)

      {:ok, _other} ->
        Logging.warning(
          "runtime_events.listener.non_object_payload",
          "runtime event ignored non-object payload",
          %{
            channel: channel
          }
        )

      {:error, reason} ->
        Logging.warning(
          "runtime_events.listener.decode_failed",
          "runtime event payload decode failed",
          %{
            channel: channel,
            reason: inspect(reason)
          }
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
