defmodule FakeFeishu.EventHub do
  @moduledoc """
  Owner process of the standalone platform State.

  Receives every `{:fake_feishu, event}` notification, converts it into one
  JSON-friendly map with a growing sequence number, keeps the newest events in
  a ring buffer, and fans them out to subscribed processes (the SSE stream and
  the standalone supervisor's seeding policy). Admin endpoints also record the
  user-side actions they perform through `record/1`, so a tail shows both
  sides of a conversation.
  """

  use GenServer

  alias FakeFeishu.State

  @buffer_limit 1000
  # Client heartbeats arrive every PingInterval and carry no information for a
  # human tail.
  @dropped_events [:ping, :token_issued]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Attaches the platform State pid once the supervisor started it."
  def attach_state(hub, state_pid), do: GenServer.call(hub, {:attach_state, state_pid})

  @doc "Records one admin-performed action as an event."
  def record(hub \\ __MODULE__, event) when is_map(event),
    do: GenServer.cast(hub, {:record, event})

  @doc """
  Subscribes the calling process. It first receives `{:hub_backlog, events}`
  with every buffered event newer than `since`, then `{:hub_event, event}`
  per new event until it exits.
  """
  def subscribe(hub \\ __MODULE__, since \\ 0),
    do: GenServer.call(hub, {:subscribe, self(), since})

  @doc "Returns buffered events newer than `since`."
  def events_since(hub \\ __MODULE__, since), do: GenServer.call(hub, {:events_since, since})

  @impl true
  def init(_opts) do
    {:ok, %{state_pid: nil, events: [], next_seq: 1, subscribers: %{}}}
  end

  @impl true
  def handle_call({:attach_state, state_pid}, _from, state) do
    {:reply, :ok, %{state | state_pid: state_pid}}
  end

  def handle_call({:subscribe, pid, since}, _from, state) do
    ref = Process.monitor(pid)
    send(pid, {:hub_backlog, newer_than(state.events, since)})
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  def handle_call({:events_since, since}, _from, state) do
    {:reply, newer_than(state.events, since), state}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    {:noreply, publish(state, event)}
  end

  @impl true
  def handle_info({:fake_feishu, event}, state) do
    case serialize(event, state.state_pid) do
      nil -> {:noreply, state}
      map -> {:noreply, publish(state, map)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp publish(state, event) do
    event =
      event
      |> Map.put("seq", state.next_seq)
      |> Map.put("ts", System.system_time(:millisecond))

    Enum.each(Map.keys(state.subscribers), &send(&1, {:hub_event, event}))

    events = Enum.take([event | state.events], @buffer_limit)
    %{state | events: events, next_seq: state.next_seq + 1}
  end

  defp newer_than(events, since) do
    events
    |> Enum.take_while(&(&1["seq"] > since))
    |> Enum.reverse()
  end

  # -- State notifications -> JSON-friendly events -----------------------------

  defp serialize(event, _state_pid) when elem(event, 0) in @dropped_events, do: nil

  defp serialize({:bot_message, message}, _state_pid) do
    %{
      "type" => "bot_message",
      "message_id" => message.id,
      "chat_id" => message.chat_id,
      "msg_type" => message.msg_type,
      "text" => message.text,
      "card_id" => message.card_id,
      "reply_to" => message.reply_to
    }
  end

  defp serialize({:bot_message_edited, message_id}, state_pid) do
    %{
      "type" => "bot_message_edited",
      "message_id" => message_id,
      "text" => state_pid && State.rendered_message_text(state_pid, message_id)
    }
  end

  defp serialize({:bot_message_deleted, message_id}, _state_pid),
    do: %{"type" => "bot_message_deleted", "message_id" => message_id}

  defp serialize({:bot_reaction, message_id, emoji_type}, _state_pid),
    do: %{"type" => "bot_reaction", "message_id" => message_id, "emoji" => emoji_type}

  defp serialize({:card_created, card_id}, _state_pid),
    do: %{"type" => "card_created", "card_id" => card_id}

  defp serialize({:card_updated, card_id, _element}, state_pid) do
    card = state_pid && State.card(state_pid, card_id)

    %{
      "type" => "card_updated",
      "card_id" => card_id,
      "message_id" => card && card.message_id,
      "text" => rendered_card_text(card, state_pid),
      "streaming" =>
        case card && get_in(card.settings, ["config", "streaming_mode"]) do
          false -> false
          _streaming_or_unknown -> true
        end
    }
  end

  defp serialize({:file_uploaded, file_key}, _state_pid),
    do: %{"type" => "file_uploaded", "file_key" => file_key}

  defp serialize({:image_uploaded, image_key}, _state_pid),
    do: %{"type" => "image_uploaded", "image_key" => image_key}

  defp serialize({:ws_connected, conn_id}, _state_pid),
    do: %{"type" => "ws_connected", "conn_id" => conn_id}

  defp serialize({:ws_disconnected, conn_id}, _state_pid),
    do: %{"type" => "ws_disconnected", "conn_id" => conn_id}

  defp serialize({:app_auto_registered, app_id}, _state_pid),
    do: %{"type" => "app_auto_registered", "app_id" => app_id}

  defp serialize({:event_acked, event_id, code}, _state_pid),
    do: %{"type" => "event_acked", "event_id" => event_id, "code" => code}

  defp serialize({:chat_put, chat}, _state_pid),
    do: %{"type" => "chat_put", "chat_id" => chat.id, "name" => chat.name}

  defp serialize(_unknown, _state_pid), do: nil

  defp rendered_card_text(nil, _state_pid), do: nil

  defp rendered_card_text(card, state_pid) do
    case card.message_id do
      nil -> nil
      message_id -> State.rendered_message_text(state_pid, message_id)
    end
  end
end
