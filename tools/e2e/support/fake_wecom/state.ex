defmodule Ankole.E2E.FakeWeCom.State do
  @moduledoc false

  use GenServer

  defstruct bot_id: "bot_fake",
            secret: "secret_fake",
            auth_errcode: 0,
            auto_ack: true,
            conns: %{},
            connection_generation: 0,
            frames: [],
            acked: MapSet.new()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       bot_id: Keyword.get(opts, :bot_id, "bot_fake"),
       secret: Keyword.get(opts, :secret, "secret_fake"),
       auth_errcode: Keyword.get(opts, :auth_errcode, 0),
       auto_ack: Keyword.get(opts, :auto_ack, true)
     }}
  end

  def register_conn(pid, conn), do: GenServer.call(pid, {:register_conn, conn})
  def connection_count(pid), do: GenServer.call(pid, :connection_count)
  def connection_generation(pid), do: GenServer.call(pid, :connection_generation)
  def close_conns(pid), do: GenServer.call(pid, :close_conns)

  @doc "Frames the client sent, oldest first, optionally filtered by cmd."
  def frames(pid, cmd \\ nil), do: GenServer.call(pid, {:frames, cmd})

  @doc "Handles one decoded client frame; returns the frames to push back."
  def handle_client_frame(pid, frame), do: GenServer.call(pid, {:client_frame, frame})

  @doc "Acks a recorded frame by req_id (manual mode)."
  def push_ack(pid, req_id, overrides \\ %{}) do
    push_frame(
      pid,
      Map.merge(
        %{"headers" => %{"req_id" => req_id}, "errcode" => 0, "errmsg" => "ok"},
        overrides
      )
    )
  end

  def push_frame(pid, frame), do: GenServer.call(pid, {:push, frame})

  def push_message(pid, req_id, body) do
    push_frame(pid, %{
      "cmd" => "aibot_msg_callback",
      "headers" => %{"req_id" => req_id},
      "body" => body
    })
  end

  def push_event(pid, req_id, eventtype, extra \\ %{}) do
    push_frame(pid, %{
      "cmd" => "aibot_event_callback",
      "headers" => %{"req_id" => req_id},
      "body" => %{
        "msgid" => "evt-#{req_id}",
        "msgtype" => "event",
        "event" => Map.merge(%{"eventtype" => eventtype}, extra)
      }
    })
  end

  @impl true
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

  def handle_call(:close_conns, _from, state) do
    Enum.each(Map.keys(state.conns), &send(&1, :close_socket))
    {:reply, :ok, state}
  end

  def handle_call({:frames, nil}, _from, state), do: {:reply, state.frames, state}

  def handle_call({:frames, cmd}, _from, state),
    do: {:reply, Enum.filter(state.frames, &(&1["cmd"] == cmd)), state}

  def handle_call({:client_frame, frame}, _from, state) do
    state = %{state | frames: state.frames ++ [frame]}
    req_id = get_in(frame, ["headers", "req_id"]) || ""

    replies =
      case frame["cmd"] do
        "aibot_subscribe" ->
          [
            %{
              "headers" => %{"req_id" => req_id},
              "errcode" => state.auth_errcode,
              "errmsg" => "ok"
            }
          ]

        "ping" ->
          [%{"headers" => %{"req_id" => req_id}, "errcode" => 0, "errmsg" => "ok"}]

        _other when state.auto_ack ->
          [%{"headers" => %{"req_id" => req_id}, "errcode" => 0, "errmsg" => "ok", "body" => %{}}]

        _other ->
          []
      end

    {:reply, replies, state}
  end

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
