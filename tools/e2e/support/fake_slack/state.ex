defmodule Ankole.E2E.FakeSlack.State do
  @moduledoc false

  use GenServer

  defstruct owner: nil,
            bot_token: "xoxb-fake",
            app_token: "xapp-fake",
            bot_user_id: "UBOT",
            team_id: "TFAKE",
            conns: %{},
            connection_generation: 0,
            acks: MapSet.new(),
            messages: %{},
            message_seq: 0,
            users: [],
            usergroups: [],
            channels: [],
            members: %{},
            inbound_files: %{},
            uploads: %{},
            upload_seq: 0

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.get(opts, :owner, self()),
       bot_token: Keyword.get(opts, :bot_token, "xoxb-fake"),
       app_token: Keyword.get(opts, :app_token, "xapp-fake"),
       users: Keyword.get(opts, :users, []),
       usergroups: Keyword.get(opts, :usergroups, []),
       channels: Keyword.get(opts, :channels, []),
       members: Keyword.get(opts, :members, %{})
     }}
  end

  def credentials(pid), do: GenServer.call(pid, :credentials)
  def register_conn(pid, conn), do: GenServer.call(pid, {:register_conn, conn})
  def push_event(pid, envelope), do: GenServer.call(pid, {:push, envelope})

  def push_disconnect(pid, reason),
    do: GenServer.call(pid, {:push, %{"type" => "disconnect", "reason" => reason}})

  def record_ack(pid, envelope_id), do: GenServer.call(pid, {:ack, envelope_id})
  def acked?(pid, envelope_id), do: GenServer.call(pid, {:acked?, envelope_id})
  def connection_count(pid), do: GenServer.call(pid, :connection_count)
  def connection_generation(pid), do: GenServer.call(pid, :connection_generation)
  def post_message(pid, body), do: GenServer.call(pid, {:post_message, body})
  def update_message(pid, body), do: GenServer.call(pid, {:update_message, body})
  def delete_message(pid, body), do: GenServer.call(pid, {:delete_message, body})
  def messages(pid), do: GenServer.call(pid, :messages)
  def users(pid), do: GenServer.call(pid, :users)
  def usergroups(pid), do: GenServer.call(pid, :usergroups)
  def channels(pid), do: GenServer.call(pid, :channels)
  def members(pid, channel), do: GenServer.call(pid, {:members, channel})

  def put_inbound_file(pid, file_id, name, content),
    do: GenServer.call(pid, {:put_inbound_file, file_id, name, content})

  def inbound_file(pid, file_id), do: GenServer.call(pid, {:inbound_file, file_id})
  def reserve_upload(pid, filename), do: GenServer.call(pid, {:reserve_upload, filename})

  def store_upload(pid, file_id, content),
    do: GenServer.call(pid, {:store_upload, file_id, content})

  def uploaded_file(pid, file_id), do: GenServer.call(pid, {:uploaded_file, file_id})

  @impl true
  def handle_call(:credentials, _from, state),
    do: {:reply, Map.take(state, [:bot_token, :app_token, :bot_user_id, :team_id]), state}

  def handle_call({:register_conn, conn}, _from, state) do
    ref = Process.monitor(conn)

    {:reply, :ok,
     %{
       state
       | conns: Map.put(state.conns, conn, ref),
         connection_generation: state.connection_generation + 1
     }}
  end

  def handle_call({:push, envelope}, _from, state) do
    live = Enum.filter(Map.keys(state.conns), &Process.alive?/1)
    Enum.each(live, &send(&1, {:push_envelope, envelope}))
    {:reply, if(live == [], do: {:error, :no_connections}, else: :ok), state}
  end

  def handle_call({:ack, envelope_id}, _from, state),
    do: {:reply, :ok, %{state | acks: MapSet.put(state.acks, envelope_id)}}

  def handle_call({:acked?, envelope_id}, _from, state),
    do: {:reply, MapSet.member?(state.acks, envelope_id), state}

  def handle_call(:connection_count, _from, state),
    do: {:reply, Enum.count(Map.keys(state.conns), &Process.alive?/1), state}

  def handle_call(:connection_generation, _from, state),
    do: {:reply, state.connection_generation, state}

  def handle_call({:post_message, body}, _from, state) do
    seq = state.message_seq + 1
    ts = "1700000000.#{seq |> Integer.to_string() |> String.pad_leading(6, "0")}"
    message = Map.merge(body, %{"ts" => ts})

    {:reply, {:ok, message},
     %{state | message_seq: seq, messages: Map.put(state.messages, ts, message)}}
  end

  def handle_call({:update_message, body}, _from, state) do
    ts = body["ts"]
    messages = Map.update(state.messages, ts, body, &Map.merge(&1, body))
    {:reply, {:ok, Map.fetch!(messages, ts)}, %{state | messages: messages}}
  end

  def handle_call({:delete_message, body}, _from, state) do
    {:reply, :ok, %{state | messages: Map.delete(state.messages, body["ts"])}}
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}
  def handle_call(:users, _from, state), do: {:reply, state.users, state}
  def handle_call(:usergroups, _from, state), do: {:reply, state.usergroups, state}
  def handle_call(:channels, _from, state), do: {:reply, state.channels, state}

  def handle_call({:members, channel}, _from, state),
    do: {:reply, Map.get(state.members, channel, []), state}

  def handle_call({:put_inbound_file, file_id, name, content}, _from, state) do
    file = %{id: file_id, name: name, content: content}
    {:reply, :ok, %{state | inbound_files: Map.put(state.inbound_files, file_id, file)}}
  end

  def handle_call({:inbound_file, file_id}, _from, state),
    do: {:reply, Map.get(state.inbound_files, file_id), state}

  def handle_call({:reserve_upload, filename}, _from, state) do
    seq = state.upload_seq + 1
    file_id = "FUPLOAD#{seq}"
    upload = %{id: file_id, name: filename, content: nil}

    {:reply, file_id,
     %{state | upload_seq: seq, uploads: Map.put(state.uploads, file_id, upload)}}
  end

  def handle_call({:store_upload, file_id, content}, _from, state) do
    uploads = Map.update!(state.uploads, file_id, &Map.put(&1, :content, content))
    {:reply, :ok, %{state | uploads: uploads}}
  end

  def handle_call({:uploaded_file, file_id}, _from, state),
    do: {:reply, Map.get(state.uploads, file_id), state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.conns, pid) do
      ^ref -> {:noreply, %{state | conns: Map.delete(state.conns, pid)}}
      _other -> {:noreply, state}
    end
  end
end
