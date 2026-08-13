defmodule FakeFeishu.State do
  @moduledoc """
  Platform state for the network-level fake Feishu server.

  Holds apps, tokens, chats, messages, CardKit cards, files, and live WS
  connections for one platform instance. Platform state changes first, WS
  events are derived from it, and one-shot fault injections run before any
  state change so a rejected send leaves no visible message behind. That is
  what lets consumers assert "gateway mirror == platform-visible state".

  The same module serves two hosts: the e2e suites start it under ExUnit with
  the test process as `owner`, and the standalone `fake-feishu` CLI starts it
  under its own supervisor with an event hub as `owner`. Every platform event
  is sent to `owner` as `{:fake_feishu, event}`.
  """

  use GenServer

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
            auto_register_apps: false,
            cardkit_enabled: false,
            client_config: @default_client_config,
            tokens: %{},
            conns: %{},
            chats: %{},
            messages: %{},
            message_order: [],
            uuid_index: %{},
            inbound_files: %{},
            uploads: %{},
            images: %{},
            cards: %{},
            faults: %{},
            acks: %{},
            ping_count: 0,
            seq: 0

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.fetch!(opts, :owner),
       auto_register_apps: Keyword.get(opts, :auto_register_apps, false),
       cardkit_enabled: Keyword.get(opts, :cardkit_enabled, false),
       client_config: Map.merge(@default_client_config, Keyword.get(opts, :client_config, %{}))
     }}
  end

  # -- consumer-facing API -----------------------------------------------------

  @doc """
  Registers a Lark app credential pair accepted by auth endpoints.

  Options: `bot_open_id:` sets the identity `bot/v3/info` reports for this app
  (defaults to `"ou_bot_" <> app_id`).
  """
  def register_app(state, app_id, app_secret, opts \\ []),
    do: GenServer.call(state, {:register_app, app_id, app_secret, opts})

  @doc "Seeds binary content served for an inbound attachment file_key."
  def put_inbound_file(state, file_key, content, name),
    do: GenServer.call(state, {:put_inbound_file, file_key, content, name})

  @doc """
  Creates or replaces one chat in the platform registry.

  Attrs: `:id` (defaults to a generated `oc_fake_*` id), `:type` (`"group"` or
  `"p2p"`), `:name`, and `:members`. A member map carries `"type"` (`"user"`
  or `"bot"`), ids, and `"name"`; bot members may carry `"app_id"` instead of
  an open id. Registered chats route pushed events to the apps whose bots are
  members; unregistered chat ids keep the default-app routing.
  """
  def put_chat(state, attrs) when is_map(attrs) or is_list(attrs),
    do: GenServer.call(state, {:put_chat, Map.new(attrs)})

  @doc "Returns every registered chat."
  def chats(state), do: GenServer.call(state, :chats)

  @doc "Returns one registered chat by id, or nil."
  def chat(state, chat_id), do: GenServer.call(state, {:chat, chat_id})

  @doc """
  Adds a member to a registered chat and pushes the matching
  `im.chat.member.user.added_v1` / `im.chat.member.bot.added_v1` event.
  """
  def add_chat_member(state, chat_id, member, attrs \\ []),
    do: GenServer.call(state, {:add_chat_member, chat_id, Map.new(member), attrs})

  @doc "Removes a member from a chat and pushes the matching removed event."
  def remove_chat_member(state, chat_id, member_key, attrs \\ []),
    do: GenServer.call(state, {:remove_chat_member, chat_id, member_key, attrs})

  @doc "Updates chat attributes and pushes `im.chat.updated_v1`."
  def update_chat(state, chat_id, changes, attrs \\ []),
    do: GenServer.call(state, {:update_chat, chat_id, Map.new(changes), attrs})

  @doc """
  Records a user message on the platform and pushes it as a real encoded event
  frame over the WS connections of the receiving app.

  `to_app:` selects which app's connections receive the event — an app id, a
  list of app ids, or `:all`. Without `to_app:` the target is derived from the
  registered chat's bot members, falling back to the first registered app for
  unregistered chat ids. Envelope attrs are `:event_id`, `:message_id`,
  `:chat_id`, `:text`, `:mentions`, ... plus frame chaos options
  `fragments: n`, `fragment_order: :reversed`, `truncate: true`.
  """
  def user_sends_message(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_sends_message, attrs})

  @doc """
  Pushes an already recorded bot-authored platform message as a receive event.

  This models the Feishu platform boundary for loop-prevention scenarios: the
  message must first have been created through the bot send/reply endpoint, then
  the fake server can deliver the platform event to other connected apps.
  """
  def broadcast_bot_message(state, message_id, attrs)
      when is_binary(message_id) and is_list(attrs),
      do: GenServer.call(state, {:broadcast_bot_message, message_id, attrs})

  @doc "Marks a message recalled and pushes the recalled event frame."
  def user_recalls_message(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_recalls_message, attrs})

  @doc """
  Records a user reaction on one message and pushes
  `im.message.reaction.created_v1`. Attrs: `:message_id`, `:emoji_type`,
  `:operator_open_id` / `:operator_user_id`, optional `:event_id`.
  """
  def user_adds_reaction(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_adds_reaction, attrs})

  @doc "Removes a user reaction and pushes `im.message.reaction.deleted_v1`."
  def user_removes_reaction(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:user_removes_reaction, attrs})

  @doc """
  Pushes a `card.action.trigger` callback frame for one interactive message.

  Attrs: `:message_id` (an interactive message), `:value` (the action value
  map or string), `:tag`, `:operator_open_id` / `:operator_user_id`, optional
  `:event_id`.
  """
  def trigger_card_action(state, attrs) when is_list(attrs),
    do: GenServer.call(state, {:trigger_card_action, attrs})

  @doc "Pushes pre-encoded frame binaries to every live WS connection."
  def push_raw_frames(state, frame_bins) when is_list(frame_bins),
    do: GenServer.call(state, {:push_raw_frames, frame_bins})

  @doc "Returns not-deleted, not-recalled messages for one chat in send order."
  def visible_messages(state, chat_id),
    do: GenServer.call(state, {:visible_messages, chat_id})

  @doc "Returns one platform message by id, or nil."
  def message(state, message_id), do: GenServer.call(state, {:message, message_id})

  @doc """
  Returns the current human-visible text of one message, or nil.

  Text messages return their text; interactive messages resolve the linked
  CardKit card and render its current element contents, so callers can watch
  streamed card updates without decoding card JSON.
  """
  def rendered_message_text(state, message_id),
    do: GenServer.call(state, {:rendered_message_text, message_id})

  @doc "Returns one CardKit card by id, or nil."
  def card(state, card_id), do: GenServer.call(state, {:card, card_id})

  @doc "Returns one uploaded outbound file by file_key, or nil."
  def uploaded_file(state, file_key), do: GenServer.call(state, {:uploaded_file, file_key})

  @doc "Returns one uploaded outbound image by image_key, or nil."
  def uploaded_image(state, image_key), do: GenServer.call(state, {:uploaded_image, image_key})

  @doc "Returns the ack code the WS client sent back for one event id, or nil."
  def ack_code(state, event_id), do: GenServer.call(state, {:ack_code, event_id})

  @doc "Returns the number of live WS connections."
  def connection_count(state), do: GenServer.call(state, :connection_count)

  @doc "Returns registered apps as `%{app_id => %{bot_open_id: ...}}`."
  def apps(state), do: GenServer.call(state, :apps)

  @doc "Closes every live WS connection from the server side."
  def drop_ws_connections(state), do: GenServer.call(state, :drop_ws_connections)

  @doc "Invalidates every issued tenant token so the next Bearer check fails."
  def expire_tokens(state), do: GenServer.call(state, :expire_tokens)

  @doc """
  Arms a one-shot fault for one server op. Ops: `:ws_endpoint`, `:tenant_token`,
  `:post_message`, `:reply_message`, `:edit_message`, `:delete_message`,
  `:add_reaction`, `:remove_reaction`, `:upload_file`, `:upload_image`,
  `:get_message`, `:download_file`, `:list_chats`, `:get_chat`,
  `:list_chat_members`, `:create_card`, `:card_element`, `:card_batch`.
  Errors: `{:code, n}`, `{:code, n, msg}`, `:http_500`, `:rate_limited`,
  `:token_invalid`.
  """
  def fail_next(state, op, error), do: GenServer.call(state, {:arm_fault, op, {:fail, error}})

  @doc "Arms a one-shot delay (milliseconds) before one server op."
  def delay_next(state, op, ms), do: GenServer.call(state, {:arm_fault, op, {:delay, ms}})

  # -- server-facing API (Router / WebSocketHandler) --------------------------------

  def authenticate_app(state, app_id, app_secret),
    do: GenServer.call(state, {:authenticate_app, app_id, app_secret})

  def issue_token(state, app_id), do: GenServer.call(state, {:issue_token, app_id})

  def verify_token(state, token), do: GenServer.call(state, {:verify_token, token})

  def take_fault(state, op), do: GenServer.call(state, {:take_fault, op})

  def bot_open_id(state, app_id), do: GenServer.call(state, {:bot_open_id, app_id})

  @doc "Returns the ClientConfig map the WS endpoint hands to connecting clients."
  def client_config(state), do: GenServer.call(state, :client_config)

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

  def store_image(state, name, content),
    do: GenServer.call(state, {:store_image, name, content})

  def fetch_download(state, message_id, file_key),
    do: GenServer.call(state, {:fetch_download, message_id, file_key})

  def list_chats(state, app_id, page_params),
    do: GenServer.call(state, {:list_chats, app_id, page_params})

  def get_chat(state, chat_id), do: GenServer.call(state, {:get_chat, chat_id})

  def list_chat_members(state, chat_id, page_params),
    do: GenServer.call(state, {:list_chat_members, chat_id, page_params})

  def cardkit_create_card(state, params),
    do: GenServer.call(state, {:cardkit_create_card, params})

  def cardkit_element_content(state, card_id, element_id, params),
    do: GenServer.call(state, {:cardkit_element_content, card_id, element_id, params})

  def cardkit_batch_update(state, card_id, params),
    do: GenServer.call(state, {:cardkit_batch_update, card_id, params})

  def register_conn(state, pid, conn_id, app_id),
    do: GenServer.call(state, {:register_conn, pid, conn_id, app_id})

  def record_ack(state, event_id, code),
    do: GenServer.call(state, {:record_ack, event_id, code})

  def record_ping(state, conn_id), do: GenServer.call(state, {:record_ping, conn_id})

  @doc "Returns the number of application-level pings received from clients."
  def ping_count(state), do: GenServer.call(state, :ping_count)

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def handle_call({:register_app, app_id, app_secret, opts}, _from, state) do
    {:reply, :ok, do_register_app(state, app_id, app_secret, opts)}
  end

  def handle_call({:put_inbound_file, file_key, content, name}, _from, state) do
    files = Map.put(state.inbound_files, file_key, %{content: content, name: name})
    {:reply, :ok, %{state | inbound_files: files}}
  end

  def handle_call({:put_chat, attrs}, _from, state) do
    {chat, state} = normalize_chat(state, attrs)
    state = %{state | chats: Map.put(state.chats, chat.id, chat)}
    notify(state, {:chat_put, chat})
    {:reply, {:ok, chat}, state}
  end

  def handle_call(:chats, _from, state) do
    {:reply, state.chats |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  def handle_call({:chat, chat_id}, _from, state) do
    {:reply, Map.get(state.chats, chat_id), state}
  end

  def handle_call({:add_chat_member, chat_id, member, attrs}, _from, state) do
    case Map.fetch(state.chats, chat_id) do
      :error ->
        {:reply, {:error, :chat_not_found}, state}

      {:ok, chat} ->
        {member, state} = normalize_member(state, member)

        chat = %{
          chat
          | members: Enum.reject(chat.members, &(&1.open_id == member.open_id)) ++ [member]
        }

        state = %{state | chats: Map.put(state.chats, chat_id, chat)}

        event_type =
          case member.type do
            "bot" -> "im.chat.member.bot.added_v1"
            _user -> "im.chat.member.user.added_v1"
          end

        state = push_member_event(state, event_type, chat, member, attrs)
        {:reply, {:ok, member}, state}
    end
  end

  def handle_call({:remove_chat_member, chat_id, member_key, attrs}, _from, state) do
    with {:ok, chat} <- Map.fetch(state.chats, chat_id),
         %{} = member <- find_member(chat, member_key) do
      chat = %{chat | members: Enum.reject(chat.members, &(&1.open_id == member.open_id))}
      state = %{state | chats: Map.put(state.chats, chat_id, chat)}

      event_type =
        case member.type do
          "bot" -> "im.chat.member.bot.deleted_v1"
          _user -> "im.chat.member.user.deleted_v1"
        end

      state = push_member_event(state, event_type, chat, member, attrs)
      {:reply, :ok, state}
    else
      _missing -> {:reply, {:error, :member_not_found}, state}
    end
  end

  def handle_call({:update_chat, chat_id, changes, attrs}, _from, state) do
    case Map.fetch(state.chats, chat_id) do
      :error ->
        {:reply, {:error, :chat_not_found}, state}

      {:ok, chat} ->
        before_name = chat.name
        chat = %{chat | name: Map.get(changes, :name, Map.get(changes, "name", chat.name))}
        state = %{state | chats: Map.put(state.chats, chat_id, chat)}

        attrs =
          attrs
          |> Keyword.put(:chat_id, chat_id)
          |> Keyword.put_new_lazy(:event_id, fn -> generated_event_id() end)
          |> Keyword.put(:before_name, before_name)
          |> Keyword.put(:after_name, chat.name)

        state = push_to_chat(state, attrs, &chat_updated_envelope/2)
        {:reply, :ok, state}
    end
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

  def handle_call({:broadcast_bot_message, message_id, attrs}, _from, state) do
    case {live_message(state, message_id), target_conns(state, attrs)} do
      {nil, _targets} ->
        {:reply, {:error, :message_not_found}, state}

      {%{sender: sender}, _targets} when sender != :bot ->
        {:reply, {:error, :not_bot_message}, state}

      {_message, []} ->
        {:reply, {:error, :no_ws_connections}, state}

      {message, targets} ->
        attrs = bot_message_event_attrs(message, attrs)
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

  def handle_call({:user_adds_reaction, attrs}, _from, state) do
    with {:ok, message, attrs} <- reaction_target(state, attrs),
         targets when targets != [] <- target_conns(state, attrs) do
      {seq, state} = next_seq(state)
      emoji_type = Keyword.fetch!(attrs, :emoji_type)

      reaction = %{
        id: "r_fake_#{seq}",
        key: emoji_type,
        operator_open_id: Keyword.get(attrs, :operator_open_id, "ou_open_alice")
      }

      state =
        update_in_message(state, message.id, fn message ->
          %{message | reactions: message.reactions ++ [reaction]}
        end)

      push_event(
        state,
        targets,
        attrs,
        &reaction_envelope(&1, &2, "im.message.reaction.created_v1")
      )

      {:reply, :ok, state}
    else
      [] -> {:reply, {:error, :no_ws_connections}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:user_removes_reaction, attrs}, _from, state) do
    with {:ok, message, attrs} <- reaction_target(state, attrs),
         targets when targets != [] <- target_conns(state, attrs) do
      emoji_type = Keyword.fetch!(attrs, :emoji_type)
      operator = Keyword.get(attrs, :operator_open_id, "ou_open_alice")

      state =
        update_in_message(state, message.id, fn message ->
          %{
            message
            | reactions:
                Enum.reject(
                  message.reactions,
                  &(&1.key == emoji_type and Map.get(&1, :operator_open_id) == operator)
                )
          }
        end)

      push_event(
        state,
        targets,
        attrs,
        &reaction_envelope(&1, &2, "im.message.reaction.deleted_v1")
      )

      {:reply, :ok, state}
    else
      [] -> {:reply, {:error, :no_ws_connections}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:trigger_card_action, attrs}, _from, state) do
    message_id = Keyword.fetch!(attrs, :message_id)

    with %{} = message <- live_message(state, message_id),
         attrs = Keyword.put_new(attrs, :chat_id, message.chat_id),
         targets when targets != [] <- target_conns(state, attrs) do
      attrs =
        attrs
        |> Keyword.put_new_lazy(:event_id, fn -> generated_event_id() end)
        |> Keyword.put(:frame_type, "card")

      push_event(state, targets, attrs, &card_action_envelope/2)
      {:reply, :ok, state}
    else
      nil -> {:reply, {:error, :message_not_found}, state}
      [] -> {:reply, {:error, :no_ws_connections}, state}
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

  def handle_call({:rendered_message_text, message_id}, _from, state) do
    {:reply, render_message_text(state, Map.get(state.messages, message_id)), state}
  end

  def handle_call({:card, card_id}, _from, state) do
    {:reply, Map.get(state.cards, card_id), state}
  end

  def handle_call({:uploaded_file, file_key}, _from, state) do
    {:reply, Map.get(state.uploads, file_key), state}
  end

  def handle_call({:uploaded_image, image_key}, _from, state) do
    {:reply, Map.get(state.images, image_key), state}
  end

  def handle_call({:ack_code, event_id}, _from, state) do
    {:reply, Map.get(state.acks, event_id), state}
  end

  def handle_call(:connection_count, _from, state) do
    {:reply, map_size(state.conns), state}
  end

  def handle_call(:apps, _from, state) do
    apps =
      Map.new(state.apps, fn {app_id, app} -> {app_id, %{bot_open_id: app.bot_open_id}} end)

    {:reply, apps, state}
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
    case {Map.fetch(state.apps, app_id), state.auto_register_apps} do
      {{:ok, %{secret: ^app_secret}}, _auto} ->
        {:reply, :ok, state}

      {{:ok, _mismatch}, _auto} ->
        {:reply, :error, state}

      {:error, true} when is_binary(app_id) and app_id != "" ->
        state = do_register_app(state, app_id, app_secret, [])
        notify(state, {:app_auto_registered, app_id})
        {:reply, :ok, state}

      {:error, _strict} ->
        {:reply, :error, state}
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

  def handle_call({:bot_open_id, app_id}, _from, state) do
    case Map.fetch(state.apps, app_id) do
      {:ok, %{bot_open_id: bot_open_id}} -> {:reply, bot_open_id, state}
      :error -> {:reply, nil, state}
    end
  end

  def handle_call(:client_config, _from, state) do
    {:reply, state.client_config, state}
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
        {state, card_id} =
          update_bot_message(state, target_id, fn message ->
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

        state = link_card_message(state, card_id, target_id)

        notify(state, {:bot_message_edited, target_id})
        {:reply, {:ok, %{"message_id" => target_id}}, state}
    end
  end

  def handle_call({:bot_delete_message, target_id}, _from, state) do
    case live_message(state, target_id) do
      nil ->
        {:reply, {:error, 23_000, "message not exist"}, state}

      _target ->
        state = update_in_message(state, target_id, fn message -> %{message | deleted: true} end)
        notify(state, {:bot_message_deleted, target_id})
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

        notify(state, {:bot_reaction, target_id, emoji_type})
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

  def handle_call({:store_image, name, content}, _from, state) do
    {seq, state} = next_seq(state)
    image_key = "img_fake_#{seq}"
    images = Map.put(state.images, image_key, %{name: name, content: content})
    notify(state, {:image_uploaded, image_key})
    {:reply, {:ok, %{"image_key" => image_key}}, %{state | images: images}}
  end

  def handle_call({:fetch_download, _message_id, file_key}, _from, state) do
    case Map.fetch(state.inbound_files, file_key) do
      {:ok, file} -> {:reply, {:ok, file}, state}
      :error -> {:reply, {:error, 23_000, "resource not exist"}, state}
    end
  end

  def handle_call({:list_chats, app_id, page_params}, _from, state) do
    bot_open_id =
      case Map.fetch(state.apps, app_id) do
        {:ok, app} -> app.bot_open_id
        :error -> nil
      end

    items =
      state.chats
      |> Map.values()
      |> Enum.filter(fn chat ->
        chat.type == "group" and
          Enum.any?(chat.members, &(&1.type == "bot" and &1.open_id == bot_open_id))
      end)
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&chat_list_item/1)

    {:reply, {:ok, paginate(items, page_params)}, state}
  end

  def handle_call({:get_chat, chat_id}, _from, state) do
    case Map.fetch(state.chats, chat_id) do
      {:ok, chat} -> {:reply, {:ok, %{"chat" => chat_info(chat)}}, state}
      :error -> {:reply, {:error, 232_002, "chat not exist"}, state}
    end
  end

  def handle_call({:list_chat_members, chat_id, page_params}, _from, state) do
    case Map.fetch(state.chats, chat_id) do
      :error ->
        {:reply, {:error, 232_002, "chat not exist"}, state}

      {:ok, chat} ->
        items = Enum.map(chat.members, &member_list_item/1)
        {:reply, {:ok, paginate(items, page_params)}, state}
    end
  end

  def handle_call({:cardkit_create_card, params}, _from, state) do
    case state.cardkit_enabled do
      false ->
        # The disabled mode intentionally exercises Lark's supported plain-text
        # fallback rather than CardKit's separate card state machine.
        {:reply, {:error, 200_860, "fake feishu: CardKit is unavailable; use plain text"}, state}

      true ->
        {seq, state} = next_seq(state)
        card_id = "crd_fake_#{seq}"

        data =
          case JSON.decode(params["data"] || "") do
            {:ok, decoded} when is_map(decoded) -> decoded
            _invalid -> %{}
          end

        card = %{
          id: card_id,
          type: params["type"] || "card_json",
          data: data,
          body_elements: get_in(data, ["body", "elements"]) || [],
          elements: %{},
          settings: %{},
          sequence: 0,
          uuids: %{},
          message_id: nil
        }

        state = %{state | cards: Map.put(state.cards, card_id, card)}
        notify(state, {:card_created, card_id})
        {:reply, {:ok, %{"card_id" => card_id}}, state}
    end
  end

  def handle_call({:cardkit_element_content, card_id, element_id, params}, _from, state) do
    with_card_mutation(state, card_id, params, fn card, state ->
      card = %{card | elements: Map.put(card.elements, element_id, params["content"] || "")}
      state = %{state | cards: Map.put(state.cards, card_id, card)}
      notify(state, {:card_updated, card_id, element_id})
      {:reply, {:ok, %{}}, state}
    end)
  end

  def handle_call({:cardkit_batch_update, card_id, params}, _from, state) do
    with_card_mutation(state, card_id, params, fn card, state ->
      actions =
        case params["actions"] do
          actions when is_list(actions) -> actions
          actions when is_binary(actions) -> decoded_actions(actions)
          _missing -> []
        end

      card = Enum.reduce(actions, card, &apply_card_action/2)
      state = %{state | cards: Map.put(state.cards, card_id, card)}
      notify(state, {:card_updated, card_id, :batch})
      {:reply, {:ok, %{}}, state}
    end)
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

  # -- apps and chats -----------------------------------------------------------

  defp do_register_app(state, app_id, app_secret, opts) do
    app = %{
      secret: app_secret,
      bot_open_id: Keyword.get(opts, :bot_open_id, "ou_bot_" <> app_id)
    }

    %{
      state
      | apps: Map.put(state.apps, app_id, app),
        default_app_id: state.default_app_id || app_id
    }
  end

  defp normalize_chat(state, attrs) do
    {id, state} =
      case chat_attr(attrs, :id) do
        nil ->
          {seq, state} = next_seq(state)
          {"oc_fake_#{seq}", state}

        id ->
          {id, state}
      end

    {members, state} =
      Enum.map_reduce(chat_attr(attrs, :members) || [], state, fn member, state ->
        normalize_member(state, Map.new(member))
      end)

    chat = %{
      id: id,
      type: chat_attr(attrs, :type) || "group",
      name: chat_attr(attrs, :name) || id,
      members: members
    }

    {chat, state}
  end

  defp chat_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_member(state, %{} = member) do
    case chat_attr(member, :type) || "user" do
      "bot" ->
        app_id = chat_attr(member, :app_id)

        open_id =
          chat_attr(member, :open_id) ||
            case Map.fetch(state.apps, app_id || "") do
              {:ok, app} -> app.bot_open_id
              :error -> "ou_bot_" <> (app_id || "unknown")
            end

        {%{
           type: "bot",
           open_id: open_id,
           user_id: nil,
           app_id: app_id,
           name: chat_attr(member, :name) || app_id || open_id
         }, state}

      _user ->
        name = chat_attr(member, :name) || "User"
        slug = member_slug(name)
        user_id = chat_attr(member, :user_id) || slug
        open_id = chat_attr(member, :open_id) || "ou_" <> slug

        {%{type: "user", open_id: open_id, user_id: user_id, app_id: nil, name: name}, state}
    end
  end

  defp member_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "user_#{System.unique_integer([:positive])}"
      slug -> slug
    end
  end

  defp find_member(chat, member_key) do
    Enum.find(chat.members, fn member ->
      member.open_id == member_key or member.user_id == member_key or member.name == member_key
    end)
  end

  defp push_member_event(state, event_type, chat, member, attrs) do
    attrs =
      attrs
      |> Keyword.put(:chat_id, chat.id)
      |> Keyword.put(:member, member)
      |> Keyword.put(:event_type, event_type)
      |> Keyword.put_new_lazy(:event_id, fn -> generated_event_id() end)

    push_to_chat(state, attrs, &member_envelope/2)
  end

  # Pushes an event derived from a registry change. Unlike
  # `user_sends_message` a missing connection is not an error, because
  # membership edits are valid while the bot is offline.
  defp push_to_chat(state, attrs, envelope_fun) do
    case target_conns(state, attrs) do
      [] -> state
      targets -> push_event(state, targets, attrs, envelope_fun)
    end
  end

  defp chat_list_item(chat) do
    %{
      "chat_id" => chat.id,
      "name" => chat.name,
      "chat_mode" => chat.type,
      "chat_type" => "private",
      "avatar" => "",
      "description" => ""
    }
  end

  defp chat_info(chat) do
    owner = Enum.find(chat.members, &(&1.type == "user"))

    chat
    |> chat_list_item()
    |> Map.merge(%{
      "owner_id" => owner && owner.user_id,
      "owner_id_type" => "user_id",
      "user_count" => chat.members |> Enum.count(&(&1.type == "user")) |> Integer.to_string()
    })
  end

  defp member_list_item(member) do
    %{
      "member_id" => member.user_id || member.open_id,
      "member_id_type" => if(member.type == "bot", do: "open_id", else: "user_id"),
      "member_type" => member.type,
      "open_id" => member.open_id,
      "name" => member.name
    }
  end

  defp paginate(items, page_params) do
    page_size = positive_int(page_params["page_size"], 50)
    offset = positive_int(page_params["page_token"], 0)

    page = Enum.slice(items, offset, page_size)
    has_more = offset + page_size < length(items)

    %{
      "items" => page,
      "has_more" => has_more,
      "page_token" => if(has_more, do: Integer.to_string(offset + page_size), else: "")
    }
  end

  defp positive_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _rest} when parsed >= 0 -> parsed
      _invalid -> default
    end
  end

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
          sender_open_id: Keyword.get(attrs, :sender_open_id),
          sender_name: Keyword.get(attrs, :sender_name),
          uuid: nil,
          card_id: nil,
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

        card_id = interactive_card_id(params)

        message = %{
          id: id,
          seq: seq,
          chat_id: chat_id,
          chat_type: nil,
          msg_type: params["msg_type"],
          content: params["content"],
          text: decoded_text(params),
          sender: :bot,
          sender_open_id: nil,
          sender_name: nil,
          uuid: uuid,
          card_id: card_id,
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

        state = link_card_message(state, card_id, id)
        notify(state, {:bot_message, message})
        {message, state}
    end
  end

  defp interactive_card_id(%{"msg_type" => "interactive", "content" => content})
       when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"type" => "card", "data" => %{"card_id" => card_id}}} when is_binary(card_id) ->
        card_id

      _other ->
        nil
    end
  end

  defp interactive_card_id(_params), do: nil

  defp update_bot_message(state, message_id, fun) do
    message = state.messages |> Map.fetch!(message_id) |> fun.()

    card_id =
      interactive_card_id(%{"msg_type" => message.msg_type, "content" => message.content})

    message = %{message | card_id: card_id}
    {%{state | messages: Map.put(state.messages, message_id, message)}, card_id}
  end

  defp link_card_message(state, nil, _message_id), do: state

  defp link_card_message(state, card_id, message_id) do
    case Map.fetch(state.cards, card_id) do
      {:ok, card} ->
        %{state | cards: Map.put(state.cards, card_id, %{card | message_id: message_id})}

      :error ->
        state
    end
  end

  defp decoded_text(%{"msg_type" => "text", "content" => content}) when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"text" => text}} -> text
      _other -> nil
    end
  end

  defp decoded_text(%{"msg_type" => "interactive", "content" => content})
       when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"body" => %{"elements" => elements}}} when is_list(elements) ->
        elements
        |> Enum.map(&element_text/1)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")

      _other ->
        nil
    end
  end

  defp decoded_text(_params), do: nil

  defp bot_message_event_attrs(message, attrs) do
    [
      event_id: Keyword.fetch!(attrs, :event_id),
      message_id: message.id,
      sender_type: "bot",
      sender_name: Keyword.get(attrs, :sender_name, "Lark Chaos Bot"),
      sender_user_id: Keyword.get(attrs, :sender_user_id, "ou_bot"),
      sender_open_id:
        Keyword.get(attrs, :sender_open_id, Keyword.get(attrs, :sender_user_id, "ou_bot")),
      chat_id: message.chat_id,
      chat_type: Keyword.get(attrs, :chat_type, message.chat_type || "group"),
      message_type: message.msg_type || "text",
      content: message.content,
      text: message.text,
      mentions: Keyword.get(attrs, :mentions, []),
      to_app: Keyword.get(attrs, :to_app, :all),
      create_time_ms:
        Keyword.get_lazy(attrs, :create_time_ms, fn -> System.system_time(:millisecond) end)
    ]
  end

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

  defp reaction_target(state, attrs) do
    message_id = Keyword.fetch!(attrs, :message_id)

    case live_message(state, message_id) do
      nil ->
        {:error, :message_not_found}

      message ->
        attrs =
          attrs
          |> Keyword.put_new(:chat_id, message.chat_id)
          |> Keyword.put_new_lazy(:event_id, fn -> generated_event_id() end)

        {:ok, message, attrs}
    end
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  defp generated_event_id, do: "evt_fake_#{System.unique_integer([:positive])}"

  defp notify(state, event), do: send(state.owner, {:fake_feishu, event})

  # -- CardKit card state --------------------------------------------------------

  # Runs the shared CardKit mutation guards (card exists, uuid idempotency,
  # strictly increasing sequence) before applying one mutation. The error
  # codes match the real platform contract the adapter's replay logic depends
  # on: 200740 missing card, 200770 consumed uuid, 300317 stale sequence.
  defp with_card_mutation(state, card_id, params, fun) do
    sequence = params["sequence"]
    uuid = params["uuid"]

    case Map.fetch(state.cards, card_id) do
      :error ->
        {:reply, {:error, 200_740, "card not exist"}, state}

      {:ok, card} ->
        cond do
          is_binary(uuid) and Map.has_key?(card.uuids, uuid) ->
            {:reply, {:error, 200_770, "uuid already consumed"}, state}

          not is_integer(sequence) or sequence <= card.sequence ->
            {:reply, {:error, 300_317, "sequence conflict"}, state}

          true ->
            card = %{card | sequence: sequence, uuids: put_uuid(card.uuids, uuid)}
            fun.(card, state)
        end
    end
  end

  defp put_uuid(uuids, uuid) when is_binary(uuid), do: Map.put(uuids, uuid, true)
  defp put_uuid(uuids, _uuid), do: uuids

  defp decoded_actions(actions_json) do
    case JSON.decode(actions_json) do
      {:ok, actions} when is_list(actions) -> actions
      {:ok, %{} = action} -> [action]
      _invalid -> []
    end
  end

  defp apply_card_action(%{"action" => "partial_update_setting", "params" => params}, card) do
    %{card | settings: deep_merge(card.settings, params["settings"] || %{})}
  end

  defp apply_card_action(%{"action" => "add_elements", "params" => params}, card) do
    %{card | body_elements: card.body_elements ++ (params["elements"] || [])}
  end

  defp apply_card_action(
         %{
           "action" => "update_element",
           "params" => %{"element_id" => element_id, "element" => element}
         },
         card
       )
       when is_binary(element_id) and is_map(element) do
    body_elements =
      Enum.map(card.body_elements, fn current ->
        if current["element_id"] == element_id,
          do: Map.put(element, "element_id", element_id),
          else: current
      end)

    %{card | body_elements: body_elements, elements: Map.delete(card.elements, element_id)}
  end

  defp apply_card_action(%{"action" => "delete_elements", "params" => params}, card) do
    ids = params["element_ids"] || []

    %{
      card
      | body_elements: Enum.reject(card.body_elements, &(Map.get(&1, "element_id") in ids)),
        elements: Map.drop(card.elements, ids)
    }
  end

  defp apply_card_action(_unknown_action, card), do: card

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right

  defp render_message_text(_state, nil), do: nil

  defp render_message_text(state, %{card_id: card_id}) when is_binary(card_id) do
    case Map.get(state.cards, card_id) do
      nil -> nil
      card -> render_card_text(card)
    end
  end

  defp render_message_text(_state, %{text: text}), do: text

  # Best-effort text of one card: static body elements overlaid with streamed
  # element contents, in body order, then any streamed element that never
  # appeared in the body. This keeps card rendering observable without
  # emulating the full card DOM.
  defp render_card_text(card) do
    body_ids =
      card.body_elements |> Enum.map(&Map.get(&1, "element_id")) |> Enum.reject(&is_nil/1)

    body_parts =
      Enum.map(card.body_elements, fn element ->
        element_id = Map.get(element, "element_id")
        Map.get(card.elements, element_id) || element_text(element)
      end)

    streamed_parts =
      card.elements
      |> Enum.reject(fn {element_id, _content} -> element_id in body_ids end)
      |> Enum.sort_by(fn {element_id, _content} -> element_id end)
      |> Enum.map(fn {_element_id, content} -> content end)

    (body_parts ++ streamed_parts)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp element_text(%{"content" => content}) when is_binary(content), do: content
  defp element_text(%{"text" => %{"content" => content}}) when is_binary(content), do: content
  defp element_text(_element), do: nil

  # -- WS event push ------------------------------------------------------------

  defp target_conns(state, attrs) do
    selector =
      Keyword.get(attrs, :to_app) || chat_member_apps(state, attrs) || state.default_app_id

    state.conns
    |> Enum.filter(fn {_pid, %{app_id: app_id}} ->
      case selector do
        :all -> true
        app_ids when is_list(app_ids) -> app_id in app_ids
        app_id_selector -> app_id == app_id_selector
      end
    end)
  end

  # Derives receiving apps from registered chat membership, mirroring the real
  # platform where a bot only receives events for chats it is in. Returns nil
  # for unregistered chat ids so those keep the default-app routing.
  defp chat_member_apps(state, attrs) do
    with chat_id when is_binary(chat_id) <- Keyword.get(attrs, :chat_id),
         %{members: members} <- Map.get(state.chats, chat_id) do
      bot_open_ids = for %{type: "bot", open_id: open_id} <- members, do: open_id

      for {app_id, %{bot_open_id: bot_open_id}} <- state.apps,
          bot_open_id in bot_open_ids,
          do: app_id
    else
      _unregistered -> nil
    end
  end

  defp push_event(state, targets, attrs, envelope_fun) do
    Enum.each(targets, fn {pid, %{app_id: app_id}} ->
      envelope = envelope_fun.(attrs, app_id || state.default_app_id)
      frames = frames_for(envelope, attrs)
      send(pid, {:push_frames, frames})
    end)

    state
  end

  defp frames_for(envelope, attrs) do
    event_id = get_in(envelope, ["header", "event_id"]) || "evt_unknown"
    payload = JSON.encode!(envelope)
    fragments = Keyword.get(attrs, :fragments, 1)
    frame_type = Keyword.get(attrs, :frame_type, "event")

    frames =
      case fragments do
        n when is_integer(n) and n > 1 ->
          payload
          |> chunk_payload(n)
          |> Enum.with_index()
          |> Enum.map(fn {part, index} ->
            frame_for(part, event_id, frame_type, [
              {"sum", Integer.to_string(n)},
              {"seq", Integer.to_string(index)}
            ])
          end)

        _one ->
          [frame_for(payload, event_id, frame_type, [])]
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

  defp frame_for(payload, event_id, frame_type, extra_headers) do
    %Frame{
      seq_id: System.unique_integer([:positive]),
      log_id: System.unique_integer([:positive]),
      service: 1001,
      method: 1,
      headers: [{"type", frame_type}, {"message_id", event_id}] ++ extra_headers,
      payload_encoding: "json",
      payload_type: "application/json",
      payload: payload,
      log_id_new: "fake-#{event_id}"
    }
  end

  # -- envelopes (schema 2.0, same shapes the provider pushes) -----------------

  defp envelope_header(attrs, app_id, event_type) do
    create_time =
      Keyword.get_lazy(attrs, :create_time_ms, fn -> System.system_time(:millisecond) end)

    %{
      "event_id" => Keyword.fetch!(attrs, :event_id),
      "event_type" => event_type,
      "create_time" => Integer.to_string(create_time),
      "tenant_key" => "tenant-chaos",
      "app_id" => Keyword.get(attrs, :app_id, app_id)
    }
  end

  defp message_envelope(attrs, app_id) do
    message_id = Keyword.fetch!(attrs, :message_id)

    create_time =
      Keyword.get_lazy(attrs, :create_time_ms, fn -> System.system_time(:millisecond) end)

    message_type = Keyword.get(attrs, :message_type, "text")

    %{
      "schema" => "2.0",
      "header" => envelope_header(attrs, app_id, "im.message.receive_v1"),
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
    message_id = Keyword.fetch!(attrs, :message_id)

    recall_time =
      Keyword.get_lazy(attrs, :recall_time_ms, fn -> System.system_time(:millisecond) end)

    %{
      "schema" => "2.0",
      "header" =>
        attrs
        |> Keyword.put(:create_time_ms, recall_time)
        |> envelope_header(app_id, "im.message.recalled_v1"),
      "event" => %{
        "message_id" => message_id,
        "chat_id" => Keyword.get(attrs, :chat_id, "oc_chaos_group"),
        "chat_type" => Keyword.get(attrs, :chat_type, "group"),
        "recall_time" => Integer.to_string(recall_time)
      }
    }
  end

  defp reaction_envelope(attrs, app_id, event_type) do
    action_time = System.system_time(:millisecond)

    %{
      "schema" => "2.0",
      "header" => envelope_header(attrs, app_id, event_type),
      "event" => %{
        "message_id" => Keyword.fetch!(attrs, :message_id),
        "chat_id" => Keyword.fetch!(attrs, :chat_id),
        "chat_type" => Keyword.get(attrs, :chat_type, "group"),
        "operator_type" => "user",
        "operator" => %{
          "user_id" => Keyword.get(attrs, :operator_user_id, "alice"),
          "open_id" => Keyword.get(attrs, :operator_open_id, "ou_open_alice"),
          "union_id" => "onion_#{Keyword.get(attrs, :operator_user_id, "alice")}"
        },
        "user_id" => %{
          "user_id" => Keyword.get(attrs, :operator_user_id, "alice"),
          "open_id" => Keyword.get(attrs, :operator_open_id, "ou_open_alice")
        },
        "reaction_type" => %{"emoji_type" => Keyword.fetch!(attrs, :emoji_type)},
        "action_time" => Integer.to_string(action_time)
      }
    }
  end

  defp member_envelope(attrs, app_id) do
    member = Keyword.fetch!(attrs, :member)

    base = %{
      "chat_id" => Keyword.fetch!(attrs, :chat_id),
      "operator_id" => %{
        "user_id" => Keyword.get(attrs, :operator_user_id, "alice"),
        "open_id" => Keyword.get(attrs, :operator_open_id, "ou_open_alice")
      },
      "external" => false,
      "operator_tenant_key" => "tenant-chaos"
    }

    event =
      case member.type do
        "bot" ->
          base

        _user ->
          Map.merge(base, %{
            "user_id" => member.user_id,
            "member" => %{
              "name" => member.name,
              "user_id" => member.user_id,
              "open_id" => member.open_id,
              "member_type" => "user"
            },
            "users" => [
              %{
                "name" => member.name,
                "user_id" => %{
                  "user_id" => member.user_id,
                  "open_id" => member.open_id,
                  "union_id" => "onion_#{member.user_id || member.open_id}"
                }
              }
            ]
          })
      end

    %{
      "schema" => "2.0",
      "header" => envelope_header(attrs, app_id, Keyword.fetch!(attrs, :event_type)),
      "event" => event
    }
  end

  defp chat_updated_envelope(attrs, app_id) do
    %{
      "schema" => "2.0",
      "header" => envelope_header(attrs, app_id, "im.chat.updated_v1"),
      "event" => %{
        "chat_id" => Keyword.fetch!(attrs, :chat_id),
        "after_change" => %{"name" => Keyword.get(attrs, :after_name)},
        "before_change" => %{"name" => Keyword.get(attrs, :before_name)}
      }
    }
  end

  defp card_action_envelope(attrs, app_id) do
    value =
      case Keyword.get(attrs, :value, %{}) do
        value when is_map(value) or is_binary(value) -> value
        other -> to_string(other)
      end

    %{
      "schema" => "2.0",
      "header" => envelope_header(attrs, app_id, "card.action.trigger"),
      "event" => %{
        "operator" => %{
          "open_id" => Keyword.get(attrs, :operator_open_id, "ou_open_alice"),
          "user_id" => Keyword.get(attrs, :operator_user_id, "alice"),
          "union_id" => "onion_#{Keyword.get(attrs, :operator_user_id, "alice")}"
        },
        "token" => "tok_fake_#{System.unique_integer([:positive])}",
        "action" => %{
          "value" => value,
          "tag" => Keyword.get(attrs, :tag, "button")
        },
        "context" => %{
          "open_message_id" => Keyword.fetch!(attrs, :message_id),
          "open_chat_id" => Keyword.fetch!(attrs, :chat_id)
        }
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
