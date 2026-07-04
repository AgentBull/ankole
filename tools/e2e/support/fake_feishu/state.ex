defmodule Ankole.E2E.FakeFeishu.State do
  @moduledoc """
  Platform state for the network-level fake Feishu server.

  Holds apps, tokens, chats/messages, files, and live WS connections for one
  test. Platform state changes first, WS events are derived from it, and
  one-shot fault injections run before any state change so a rejected send
  leaves no visible message behind. That is what lets tests assert
  "gateway mirror == platform-visible state".
  """

  use GenServer

  alias Ankole.JSON
  alias FeishuOpenAPI.WS.Frame

  @default_client_config %{
    # Short intervals keep heartbeats and reconnects fast in tests without
    # touching the real client defaults.
    "PingInterval" => 1,
    "ReconnectInterval" => 1,
    "ReconnectNonce" => 1,
    "ReconnectCount" => -1
  }

  defstruct owner: nil,
            apps: %{},
            default_app_id: nil,
            tokens: %{},
            conns: %{},
            messages: %{},
            message_order: [],
            uuid_index: %{},
            inbound_files: %{},
            uploads: %{},
            faults: %{},
            acks: %{},
            ping_count: 0,
            seq: 0

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{owner: Keyword.fetch!(opts, :owner)}}
  end

  # -- test-facing API -------------------------------------------------------

  @doc "Registers a Lark app credential pair accepted by auth endpoints."
  def register_app(state, app_id, app_secret),
    do: GenServer.call(state, {:register_app, app_id, app_secret})

  @doc "Seeds binary content served for an inbound attachment file_key."
  def put_inbound_file(state, file_key, content, name),
    do: GenServer.call(state, {:put_inbound_file, file_key, content, name})

  @doc """
  Records a user message on the platform and pushes it as a real encoded event
  frame over the WS connections of the receiving app.

  `to_app:` selects which app's connections receive the event — an app id, a
  list of app ids, or `:all`. It defaults to the first registered app, which
  models "the bot is only in the chats its scenarios use". Envelope attrs are
  `:event_id`, `:message_id`, `:chat_id`, `:text`, `:mentions`, ... plus frame
  chaos options `fragments: n`, `fragment_order: :reversed`, `truncate: true`.
  """
  def user_sends_message(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_sends_message, attrs})

  @doc "Marks a message recalled and pushes the recalled event frame."
  def user_recalls_message(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_recalls_message, attrs})

  @doc "Pushes pre-encoded frame binaries to every live WS connection."
  def push_raw_frames(state, frame_bins) when is_list(frame_bins),
    do: GenServer.call(state, {:push_raw_frames, frame_bins})

  @doc "Returns not-deleted, not-recalled messages for one chat in send order."
  def visible_messages(state, chat_id),
    do: GenServer.call(state, {:visible_messages, chat_id})

  @doc "Returns one platform message by id, or nil."
  def message(state, message_id), do: GenServer.call(state, {:message, message_id})

  @doc "Returns one uploaded outbound file by file_key, or nil."
  def uploaded_file(state, file_key), do: GenServer.call(state, {:uploaded_file, file_key})

  @doc "Returns the ack code the WS client sent back for one event id, or nil."
  def ack_code(state, event_id), do: GenServer.call(state, {:ack_code, event_id})

  @doc "Returns the number of live WS connections."
  def connection_count(state), do: GenServer.call(state, :connection_count)

  @doc "Closes every live WS connection from the server side."
  def drop_ws_connections(state), do: GenServer.call(state, :drop_ws_connections)

  @doc "Invalidates every issued tenant token so the next Bearer check fails."
  def expire_tokens(state), do: GenServer.call(state, :expire_tokens)

  @doc """
  Arms a one-shot fault for one server op. Ops: `:ws_endpoint`, `:tenant_token`,
  `:post_message`, `:reply_message`, `:edit_message`, `:delete_message`,
  `:add_reaction`, `:remove_reaction`, `:upload_file`, `:get_message`,
  `:download_file`. Errors: `{:code, n}`, `{:code, n, msg}`, `:http_500`,
  `:rate_limited`, `:token_invalid`.
  """
  def fail_next(state, op, error), do: GenServer.call(state, {:arm_fault, op, {:fail, error}})

  @doc "Arms a one-shot delay (milliseconds) before one server op."
  def delay_next(state, op, ms), do: GenServer.call(state, {:arm_fault, op, {:delay, ms}})

  # -- server-facing API (Router / WsHandler) --------------------------------

  def authenticate_app(state, app_id, app_secret),
    do: GenServer.call(state, {:authenticate_app, app_id, app_secret})

  def issue_token(state, app_id), do: GenServer.call(state, {:issue_token, app_id})

  def verify_token(state, token), do: GenServer.call(state, {:verify_token, token})

  def take_fault(state, op), do: GenServer.call(state, {:take_fault, op})

  def bot_post_message(state, params), do: GenServer.call(state, {:bot_post_message, params})

  def bot_reply_message(state, target_id, params),
    do: GenServer.call(state, {:bot_reply_message, target_id, params})

  def bot_edit_message(state, target_id, params),
    do: GenServer.call(state, {:bot_edit_message, target_id, params})

  def bot_delete_message(state, target_id),
    do: GenServer.call(state, {:bot_delete_message, target_id})

  def bot_add_reaction(state, target_id, emoji_type),
    do: GenServer.call(state, {:bot_add_reaction, target_id, emoji_type})

  def bot_remove_reaction(state, target_id, reaction_id),
    do: GenServer.call(state, {:bot_remove_reaction, target_id, reaction_id})

  def get_message(state, message_id), do: GenServer.call(state, {:get_message, message_id})

  def store_upload(state, name, content),
    do: GenServer.call(state, {:store_upload, name, content})

  def fetch_download(state, message_id, file_key),
    do: GenServer.call(state, {:fetch_download, message_id, file_key})

  def register_conn(state, pid, conn_id, app_id),
    do: GenServer.call(state, {:register_conn, pid, conn_id, app_id})

  def record_ack(state, event_id, code),
    do: GenServer.call(state, {:record_ack, event_id, code})

  def record_ping(state, conn_id), do: GenServer.call(state, {:record_ping, conn_id})

  @doc "Returns the number of application-level pings received from clients."
  def ping_count(state), do: GenServer.call(state, :ping_count)

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def handle_call({:register_app, app_id, app_secret}, _from, state) do
    state = %{
      state
      | apps: Map.put(state.apps, app_id, app_secret),
        default_app_id: state.default_app_id || app_id
    }

    {:reply, :ok, state}
  end

  def handle_call({:put_inbound_file, file_key, content, name}, _from, state) do
    files = Map.put(state.inbound_files, file_key, %{content: content, name: name})
    {:reply, :ok, %{state | inbound_files: files}}
  end

  def handle_call({:user_sends_message, attrs}, _from, state) do
    case target_conns(state, attrs) do
      [] ->
        {:reply, {:error, :no_ws_connections}, state}

      targets ->
        message_id = Keyword.fetch!(attrs, :message_id)
        state = record_user_message(state, message_id, attrs)
        push_event(state, targets, attrs, &message_envelope/2)
        {:reply, :ok, state}
    end
  end

  def handle_call({:user_recalls_message, attrs}, _from, state) do
    case target_conns(state, attrs) do
      [] ->
        {:reply, {:error, :no_ws_connections}, state}

      targets ->
        message_id = Keyword.fetch!(attrs, :message_id)

        state =
          update_in_message(state, message_id, fn message ->
            %{message | recalled: true}
          end)

        push_event(state, targets, attrs, &recalled_envelope/2)
        {:reply, :ok, state}
    end
  end

  def handle_call({:push_raw_frames, frame_bins}, _from, state) do
    case map_size(state.conns) do
      0 ->
        {:reply, {:error, :no_ws_connections}, state}

      _count ->
        Enum.each(Map.keys(state.conns), fn pid ->
          send(pid, {:push_frames, frame_bins})
        end)

        {:reply, :ok, state}
    end
  end

  def handle_call({:visible_messages, chat_id}, _from, state) do
    messages =
      state.message_order
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(state.messages, &1))
      |> Enum.filter(fn message ->
        message.chat_id == chat_id and not message.recalled and not message.deleted
      end)

    {:reply, messages, state}
  end

  def handle_call({:message, message_id}, _from, state) do
    {:reply, Map.get(state.messages, message_id), state}
  end

  def handle_call({:uploaded_file, file_key}, _from, state) do
    {:reply, Map.get(state.uploads, file_key), state}
  end

  def handle_call({:ack_code, event_id}, _from, state) do
    {:reply, Map.get(state.acks, event_id), state}
  end

  def handle_call(:connection_count, _from, state) do
    {:reply, map_size(state.conns), state}
  end

  def handle_call(:drop_ws_connections, _from, state) do
    Enum.each(Map.keys(state.conns), fn pid -> send(pid, {:fake_feishu_close, 1000}) end)
    {:reply, :ok, state}
  end

  def handle_call(:expire_tokens, _from, state) do
    {:reply, :ok, %{state | tokens: %{}}}
  end

  def handle_call({:arm_fault, op, fault}, _from, state) do
    faults = Map.update(state.faults, op, [fault], &(&1 ++ [fault]))
    {:reply, :ok, %{state | faults: faults}}
  end

  def handle_call({:authenticate_app, app_id, app_secret}, _from, state) do
    case Map.fetch(state.apps, app_id) do
      {:ok, ^app_secret} -> {:reply, :ok, state}
      _mismatch -> {:reply, :error, state}
    end
  end

  def handle_call({:issue_token, app_id}, _from, state) do
    {seq, state} = next_seq(state)
    token = "t-fake-#{app_id}-#{seq}"
    notify(state, {:token_issued, token})
    {:reply, token, %{state | tokens: Map.put(state.tokens, token, app_id)}}
  end

  def handle_call({:verify_token, token}, _from, state) do
    case Map.fetch(state.tokens, token) do
      {:ok, app_id} -> {:reply, {:ok, app_id}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:take_fault, op}, _from, state) do
    case Map.get(state.faults, op, []) do
      [] ->
        {:reply, nil, state}

      [fault | rest] ->
        {:reply, fault, %{state | faults: Map.put(state.faults, op, rest)}}
    end
  end

  def handle_call({:bot_post_message, params}, _from, state) do
    {message, state} = insert_bot_message(state, params, nil)
    {:reply, {:ok, %{"message_id" => message.id}}, state}
  end

  def handle_call({:bot_reply_message, target_id, params}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      target ->
        {message, state} = insert_bot_message(state, params, target)
        {:reply, {:ok, %{"message_id" => message.id, "root_id" => message.root_id}}, state}
    end
  end

  def handle_call({:bot_edit_message, target_id, params}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      _target ->
        state =
          update_in_message(state, target_id, fn message ->
            msg_type = params["msg_type"] || message.msg_type
            content = params["content"] || message.content

            %{
              message
              | msg_type: msg_type,
                content: content,
                text:
                  decoded_text(%{"msg_type" => msg_type, "content" => content}) || message.text
            }
          end)

        {:reply, {:ok, %{"message_id" => target_id}}, state}
    end
  end

  def handle_call({:bot_delete_message, target_id}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      _target ->
        state = update_in_message(state, target_id, fn message -> %{message | deleted: true} end)
        {:reply, {:ok, %{}}, state}
    end
  end

  def handle_call({:bot_add_reaction, target_id, emoji_type}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      _target ->
        {seq, state} = next_seq(state)
        reaction_id = "r_fake_#{seq}"

        state =
          update_in_message(state, target_id, fn message ->
            %{message | reactions: message.reactions ++ [%{id: reaction_id, key: emoji_type}]}
          end)

        {:reply, {:ok, %{"reaction_id" => reaction_id}}, state}
    end
  end

  def handle_call({:bot_remove_reaction, target_id, reaction_id}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      _target ->
        state =
          update_in_message(state, target_id, fn message ->
            %{message | reactions: Enum.reject(message.reactions, &(&1.id == reaction_id))}
          end)

        {:reply, {:ok, %{}}, state}
    end
  end

  def handle_call({:get_message, message_id}, _from, state) do
    case live_message(state, message_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      message ->
        item = %{
          "message_id" => message.id,
          "chat_id" => message.chat_id,
          "msg_type" => message.msg_type,
          "body" => %{"content" => message.content}
        }

        {:reply, {:ok, %{"items" => [item]}}, state}
    end
  end

  def handle_call({:store_upload, name, content}, _from, state) do
    {seq, state} = next_seq(state)
    file_key = "fake_file_#{seq}"
    uploads = Map.put(state.uploads, file_key, %{name: name, content: content})
    notify(state, {:file_uploaded, file_key})
    {:reply, {:ok, %{"file_key" => file_key}}, %{state | uploads: uploads}}
  end

  def handle_call({:fetch_download, _message_id, file_key}, _from, state) do
    case Map.fetch(state.inbound_files, file_key) do
      {:ok, file} -> {:reply, {:ok, file}, state}
      :error -> {:reply, {:error, 23_000, "resource not exist"}, state}
    end
  end

  def handle_call({:register_conn, pid, conn_id, app_id}, _from, state) do
    ref = Process.monitor(pid)
    conns = Map.put(state.conns, pid, %{conn_id: conn_id, app_id: app_id, ref: ref})
    notify(state, {:ws_connected, conn_id})
    {:reply, :ok, %{state | conns: conns}}
  end

  def handle_call({:record_ack, event_id, code}, _from, state) do
    notify(state, {:event_acked, event_id, code})
    {:reply, :ok, %{state | acks: Map.put(state.acks, event_id, code)}}
  end

  def handle_call({:record_ping, conn_id}, _from, state) do
    notify(state, {:ping, conn_id})
    {:reply, :ok, %{state | ping_count: state.ping_count + 1}}
  end

  def handle_call(:ping_count, _from, state) do
    {:reply, state.ping_count, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.conns, pid) do
      {nil, _conns} ->
        {:noreply, state}

      {%{conn_id: conn_id}, conns} ->
        notify(state, {:ws_disconnected, conn_id})
        {:noreply, %{state | conns: conns}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- platform message state -------------------------------------------------

  defp record_user_message(state, message_id, attrs) do
    case Map.has_key?(state.messages, message_id) do
      true ->
        # A duplicate push re-delivers the event but the platform message
        # already exists (and stays tombstoned if it was recalled).
        state

      false ->
        {seq, state} = next_seq(state)
        message_type = Keyword.get(attrs, :message_type, "text")

        message = %{
          id: message_id,
          seq: seq,
          chat_id: Keyword.get(attrs, :chat_id, "oc_chaos_group"),
          chat_type: Keyword.get(attrs, :chat_type, "group"),
          msg_type: message_type,
          content: message_content(attrs, message_type),
          text: Keyword.get(attrs, :text),
          sender: :user,
          uuid: nil,
          reply_to: Keyword.get(attrs, :parent_id),
          root_id: Keyword.get(attrs, :root_id),
          reactions: [],
          recalled: false,
          deleted: false
        }

        put_message(state, message)
    end
  end

  defp insert_bot_message(state, params, target) do
    uuid = params["uuid"]

    case is_binary(uuid) and Map.has_key?(state.uuid_index, uuid) do
      true ->
        # Lark treats uuid as an idempotency key: a resend returns the already
        # created message instead of duplicating platform state.
        message = Map.fetch!(state.messages, Map.fetch!(state.uuid_index, uuid))
        {message, state}

      false ->
        {seq, state} = next_seq(state)
        id = "om_fake_out_#{seq}"

        chat_id =
          case target do
            %{chat_id: chat_id} -> chat_id
            nil -> params["receive_id"]
          end

        message = %{
          id: id,
          seq: seq,
          chat_id: chat_id,
          chat_type: nil,
          msg_type: params["msg_type"],
          content: params["content"],
          text: decoded_text(params),
          sender: :bot,
          uuid: uuid,
          reply_to: target && target.id,
          root_id: (target && (target.root_id || target.id)) || nil,
          reactions: [],
          recalled: false,
          deleted: false
        }

        state = put_message(state, message)

        state =
          case is_binary(uuid) do
            true -> %{state | uuid_index: Map.put(state.uuid_index, uuid, id)}
            false -> state
          end

        notify(state, {:bot_message, message})
        {message, state}
    end
  end

  defp decoded_text(%{"msg_type" => "text", "content" => content}) when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"text" => text}} -> text
      _other -> nil
    end
  end

  defp decoded_text(_params), do: nil

  defp put_message(state, message) do
    %{
      state
      | messages: Map.put(state.messages, message.id, message),
        message_order: [message.id | state.message_order]
    }
  end

  defp update_in_message(state, message_id, fun) do
    case Map.fetch(state.messages, message_id) do
      {:ok, message} -> %{state | messages: Map.put(state.messages, message_id, fun.(message))}
      :error -> state
    end
  end

  defp live_message(state, message_id) do
    case Map.get(state.messages, message_id) do
      %{recalled: false, deleted: false} = message -> message
      _gone_or_missing -> nil
    end
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  defp notify(state, event), do: send(state.owner, {:fake_feishu, event})

  # -- WS event push ------------------------------------------------------------

  @doc "Returns the ClientConfig map the WS endpoint hands to connecting clients."
  def client_config, do: @default_client_config

  defp target_conns(state, attrs) do
    selector = Keyword.get(attrs, :to_app, state.default_app_id)

    state.conns
    |> Enum.filter(fn {_pid, %{app_id: app_id}} ->
      case selector do
        :all -> true
        app_ids when is_list(app_ids) -> app_id in app_ids
        app_id_selector -> app_id == app_id_selector
      end
    end)
  end

  defp push_event(state, targets, attrs, envelope_fun) do
    Enum.each(targets, fn {pid, %{app_id: app_id}} ->
      envelope = envelope_fun.(attrs, app_id || state.default_app_id)
      frames = frames_for(envelope, attrs)
      send(pid, {:push_frames, frames})
    end)
  end

  defp frames_for(envelope, attrs) do
    event_id = get_in(envelope, ["header", "event_id"]) || "evt_unknown"
    payload = JSON.encode!(envelope)
    fragments = Keyword.get(attrs, :fragments, 1)

    frames =
      case fragments do
        n when is_integer(n) and n > 1 ->
          payload
          |> chunk_payload(n)
          |> Enum.with_index()
          |> Enum.map(fn {part, index} ->
            frame_for(part, event_id, [
              {"sum", Integer.to_string(n)},
              {"seq", Integer.to_string(index)}
            ])
          end)

        _one ->
          [frame_for(payload, event_id, [])]
      end

    frames =
      case Keyword.get(attrs, :fragment_order, :in_order) do
        :reversed -> Enum.reverse(frames)
        _in_order -> frames
      end

    frames
    |> Enum.map(&Frame.encode/1)
    |> maybe_truncate(Keyword.get(attrs, :truncate, false))
  end

  defp maybe_truncate(encoded_frames, true) do
    Enum.map(encoded_frames, fn bin ->
      binary_part(bin, 0, max(byte_size(bin) - 2, 0))
    end)
  end

  defp maybe_truncate(encoded_frames, _false), do: encoded_frames

  defp chunk_payload(payload, n) do
    size = byte_size(payload)
    chunk = max(div(size, n) + 1, 1)

    payload
    |> :binary.bin_to_list()
    |> Enum.chunk_every(chunk)
    |> Enum.map(&:erlang.list_to_binary/1)
  end

  defp frame_for(payload, event_id, extra_headers) do
    %Frame{
      seq_id: System.unique_integer([:positive]),
      log_id: System.unique_integer([:positive]),
      service: 1001,
      method: 1,
      headers: [{"type", "event"}, {"message_id", event_id}] ++ extra_headers,
      payload_encoding: "json",
      payload_type: "application/json",
      payload: payload,
      log_id_new: "fake-#{event_id}"
    }
  end

  # -- envelopes (schema 2.0, same shapes the provider pushes) -----------------

  defp message_envelope(attrs, app_id) do
    event_id = Keyword.fetch!(attrs, :event_id)
    message_id = Keyword.fetch!(attrs, :message_id)

    create_time =
      Keyword.get_lazy(attrs, :create_time_ms, fn -> System.system_time(:millisecond) end)

    message_type = Keyword.get(attrs, :message_type, "text")

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "create_time" => Integer.to_string(create_time),
        "tenant_key" => "tenant-chaos",
        "app_id" => Keyword.get(attrs, :app_id, app_id)
      },
      "event" => %{
        "sender" => %{
          "sender_type" => Keyword.get(attrs, :sender_type, "user"),
          "sender_name" => Keyword.get(attrs, :sender_name, "Alice Chaos"),
          "sender_id" => %{
            "user_id" => Keyword.get(attrs, :sender_user_id, "ou_alice"),
            "open_id" => Keyword.get(attrs, :sender_open_id, "ou_open_alice"),
            "union_id" => "onion_#{Keyword.get(attrs, :sender_user_id, "ou_alice")}"
          }
        },
        "message" => %{
          "message_id" => message_id,
          "root_id" => Keyword.get(attrs, :root_id),
          "parent_id" => Keyword.get(attrs, :parent_id),
          "chat_id" => Keyword.get(attrs, :chat_id, "oc_chaos_group"),
          "chat_type" => Keyword.get(attrs, :chat_type, "group"),
          "message_type" => message_type,
          "content" => message_content(attrs, message_type),
          "mentions" => Keyword.get(attrs, :mentions, []),
          "create_time" => Integer.to_string(create_time)
        }
      }
    }
  end

  defp recalled_envelope(attrs, app_id) do
    event_id = Keyword.fetch!(attrs, :event_id)
    message_id = Keyword.fetch!(attrs, :message_id)

    recall_time =
      Keyword.get_lazy(attrs, :recall_time_ms, fn -> System.system_time(:millisecond) end)

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.recalled_v1",
        "create_time" => Integer.to_string(recall_time),
        "tenant_key" => "tenant-chaos",
        "app_id" => Keyword.get(attrs, :app_id, app_id)
      },
      "event" => %{
        "message_id" => message_id,
        "chat_id" => Keyword.get(attrs, :chat_id, "oc_chaos_group"),
        "chat_type" => Keyword.get(attrs, :chat_type, "group"),
        "recall_time" => Integer.to_string(recall_time)
      }
    }
  end

  defp message_content(attrs, message_type) do
    case Keyword.fetch(attrs, :content) do
      {:ok, content} when is_binary(content) ->
        content

      {:ok, content} when is_map(content) ->
        JSON.encode!(content)

      :error when message_type == "text" ->
        JSON.encode!(%{"text" => Keyword.get(attrs, :text, "")})

      :error ->
        JSON.encode!(%{})
    end
  end
end
