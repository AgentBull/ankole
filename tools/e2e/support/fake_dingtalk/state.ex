defmodule Ankole.E2E.FakeDingTalk.State do
  @moduledoc false

  use GenServer

  defstruct owner: nil,
            client_id: "cli_fake",
            client_secret: "secret_fake",
            conns: %{},
            connection_generation: 0,
            ticket_seq: 0,
            register_bodies: [],
            acks: %{}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.get(opts, :owner, self()),
       client_id: Keyword.get(opts, :client_id, "cli_fake"),
       client_secret: Keyword.get(opts, :client_secret, "secret_fake")
     }}
  end

  def next_ticket(pid), do: GenServer.call(pid, :next_ticket)
  def record_register(pid, body), do: GenServer.call(pid, {:record_register, body})
  def register_bodies(pid), do: GenServer.call(pid, :register_bodies)
  def register_conn(pid, conn), do: GenServer.call(pid, {:register_conn, conn})
  def connection_count(pid), do: GenServer.call(pid, :connection_count)
  def connection_generation(pid), do: GenServer.call(pid, :connection_generation)
  def record_ack(pid, message_id, response), do: GenServer.call(pid, {:ack, message_id, response})
  def acked?(pid, message_id), do: GenServer.call(pid, {:acked?, message_id})
  def ack_response(pid, message_id), do: GenServer.call(pid, {:ack_response, message_id})

  def push_frame(pid, frame), do: GenServer.call(pid, {:push, frame})

  def push_ping(pid, message_id, opaque) do
    push_frame(pid, %{
      "specVersion" => "1.0",
      "type" => "SYSTEM",
      "headers" => %{
        "topic" => "ping",
        "messageId" => message_id,
        "contentType" => "application/json"
      },
      "data" => Torque.encode!(%{"opaque" => opaque})
    })
  end

  def push_callback(pid, message_id, topic, data) do
    push_frame(pid, %{
      "type" => "CALLBACK",
      "headers" => %{
        "topic" => topic,
        "messageId" => message_id,
        "contentType" => "application/json"
      },
      "data" => Torque.encode!(data)
    })
  end

  def push_event(pid, message_id, event_type, data) do
    push_frame(pid, %{
      "type" => "EVENT",
      "headers" => %{
        "eventType" => event_type,
        "messageId" => message_id,
        "eventId" => "evt-#{message_id}",
        "contentType" => "application/json"
      },
      "data" => Torque.encode!(data)
    })
  end

  def push_disconnect(pid) do
    push_frame(pid, %{
      "type" => "SYSTEM",
      "headers" => %{"topic" => "disconnect", "messageId" => "disconnect"}
    })
  end

  @impl true
  def handle_call(:next_ticket, _from, state) do
    seq = state.ticket_seq + 1
    {:reply, "ticket-#{seq}", %{state | ticket_seq: seq}}
  end

  def handle_call({:record_register, body}, _from, state),
    do: {:reply, :ok, %{state | register_bodies: state.register_bodies ++ [body]}}

  def handle_call(:register_bodies, _from, state),
    do: {:reply, state.register_bodies, state}

  def handle_call({:register_conn, conn}, _from, state) do
    ref = Process.monitor(conn)

    {:reply, :ok,
     %{
       state
       | conns: Map.put(state.conns, conn, ref),
         connection_generation: state.connection_generation + 1
     }}
  end

  def handle_call(:connection_count, _from, state),
    do: {:reply, Enum.count(Map.keys(state.conns), &Process.alive?/1), state}

  def handle_call(:connection_generation, _from, state),
    do: {:reply, state.connection_generation, state}

  def handle_call({:ack, message_id, response}, _from, state),
    do: {:reply, :ok, %{state | acks: Map.put(state.acks, message_id, response)}}

  def handle_call({:acked?, message_id}, _from, state),
    do: {:reply, Map.has_key?(state.acks, message_id), state}

  def handle_call({:ack_response, message_id}, _from, state),
    do: {:reply, Map.get(state.acks, message_id), state}

  def handle_call({:push, frame}, _from, state) do
    live = Enum.filter(Map.keys(state.conns), &Process.alive?/1)
    Enum.each(live, &send(&1, {:push_frame, frame}))
    {:reply, if(live == [], do: {:error, :no_connections}, else: :ok), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.conns, pid) do
      ^ref -> {:noreply, %{state | conns: Map.delete(state.conns, pid)}}
      _other -> {:noreply, state}
    end
  end
end
