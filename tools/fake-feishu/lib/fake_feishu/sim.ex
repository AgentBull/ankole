defmodule FakeFeishu.Sim do
  @moduledoc """
  User-side simulation operations on top of `FakeFeishu.State`.

  The admin API and the standalone seeding policy both go through this module:
  it resolves chats and member personas, builds real Feishu envelope inputs
  (mentions, reply threading, attachments), performs the State change, and
  records the user-side action on the `FakeFeishu.EventHub` so a tail shows
  the full conversation.
  """

  alias FakeFeishu.EventHub
  alias FakeFeishu.State

  @general_chat_id "oc_sim_general"

  def general_chat_id, do: @general_chat_id

  @doc """
  Seeds the default rooms for one app: a shared "General" group with every
  default user plus this bot, and a p2p chat between the first user and this
  bot. Repeated calls only add the bot to the existing general chat.
  """
  def seed_default_chats(state, app_id, user_names) do
    users = Enum.map(user_names, &%{"type" => "user", "name" => &1})
    bot = %{"type" => "bot", "app_id" => app_id}

    case State.chat(state, @general_chat_id) do
      nil ->
        {:ok, _chat} =
          State.put_chat(state, %{
            "id" => @general_chat_id,
            "type" => "group",
            "name" => "General",
            "members" => users ++ [bot]
          })

        :ok

      %{members: members} ->
        if not Enum.any?(members, &(&1.app_id == app_id)) do
          {:ok, _member} = State.add_chat_member(state, @general_chat_id, bot)
        end

        :ok
    end

    p2p_id = "oc_sim_p2p_" <> app_id

    if State.chat(state, p2p_id) == nil do
      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => p2p_id,
          "type" => "p2p",
          "name" => "p2p: #{List.first(user_names) || "User"} & #{app_id}",
          "members" => Enum.take(users, 1) ++ [bot]
        })
    end

    :ok
  end

  @doc """
  Sends one message as a chat member and returns `{:ok, ids}`.

  Params (string keys): `"text"`, `"as"` (member name / user_id / open_id;
  defaults to the first user member), `"mention_bot"`, `"reply_to"`,
  `"message_type"` + `"content"`, `"file"` / `"image"` (`%{"name", "base64"}`).
  """
  def send_user_message(state, chat_id, params) do
    with {:ok, chat} <- fetch_chat(state, chat_id),
         {:ok, sender} <- resolve_sender(chat, params["as"]) do
      token = State.run_token(state)
      message_id = "om_sim_#{token}_#{System.unique_integer([:positive])}"
      event_id = "evt_sim_#{token}_#{System.unique_integer([:positive])}"

      attrs =
        [
          message_id: message_id,
          event_id: event_id,
          chat_id: chat.id,
          chat_type: chat.type,
          sender_name: sender.name,
          sender_user_id: sender.user_id,
          sender_open_id: sender.open_id
        ]
        |> put_body(state, chat, params)
        |> put_mentions(chat, params)
        |> put_reply(state, params)

      case State.user_sends_message(state, attrs) do
        :ok ->
          EventHub.record(%{
            "type" => "user_message",
            "message_id" => message_id,
            "event_id" => event_id,
            "chat_id" => chat.id,
            "sender_name" => sender.name,
            "msg_type" => Keyword.get(attrs, :message_type, "text"),
            "text" => Keyword.get(attrs, :text)
          })

          {:ok, %{"message_id" => message_id, "event_id" => event_id, "chat_id" => chat.id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Recalls one message as its chat's user and pushes the recalled event."
  def recall_message(state, message_id) do
    with {:ok, message} <- fetch_message(state, message_id) do
      attrs = [
        message_id: message_id,
        event_id: "evt_sim_#{State.run_token(state)}_#{System.unique_integer([:positive])}",
        chat_id: message.chat_id,
        chat_type: message.chat_type || "group"
      ]

      case State.user_recalls_message(state, attrs) do
        :ok ->
          EventHub.record(%{
            "type" => "user_recalled",
            "message_id" => message_id,
            "chat_id" => message.chat_id
          })

          {:ok, %{"message_id" => message_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Adds or removes a user reaction and pushes the reaction event."
  def react(state, message_id, params, action) do
    with {:ok, message} <- fetch_message(state, message_id),
         {:ok, operator} <- resolve_operator(state, message, params["as"]) do
      attrs = [
        message_id: message_id,
        emoji_type: params["emoji"] || "THUMBSUP",
        operator_user_id: operator.user_id,
        operator_open_id: operator.open_id
      ]

      result =
        case action do
          :add -> State.user_adds_reaction(state, attrs)
          :remove -> State.user_removes_reaction(state, attrs)
        end

      case result do
        :ok ->
          EventHub.record(%{
            "type" => "user_reaction",
            "action" => Atom.to_string(action),
            "message_id" => message_id,
            "emoji" => attrs[:emoji_type],
            "operator" => operator.name
          })

          {:ok, %{"message_id" => message_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Triggers a card action callback on one interactive message."
  def card_action(state, message_id, params) do
    with {:ok, message} <- fetch_message(state, message_id),
         {:ok, operator} <- resolve_operator(state, message, params["as"]) do
      attrs = [
        message_id: message_id,
        value: params["value"] || %{},
        tag: params["tag"] || "button",
        operator_user_id: operator.user_id,
        operator_open_id: operator.open_id
      ]

      case State.trigger_card_action(state, attrs) do
        :ok ->
          EventHub.record(%{
            "type" => "user_card_action",
            "message_id" => message_id,
            "value" => params["value"],
            "operator" => operator.name
          })

          {:ok, %{"message_id" => message_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Returns the transcript of one chat with resolved message texts."
  def transcript(state, chat_id) do
    state
    |> State.visible_messages(chat_id)
    |> Enum.map(fn message ->
      %{
        "message_id" => message.id,
        "sender" => Atom.to_string(message.sender),
        "sender_name" => message.sender_name || default_sender_name(message.sender),
        "msg_type" => message.msg_type,
        "text" => State.rendered_message_text(state, message.id),
        "content" => message.content,
        "card_id" => message.card_id,
        "reply_to" => message.reply_to,
        "reactions" => Enum.map(message.reactions, & &1.key)
      }
    end)
  end

  @doc "Returns chats as JSON-friendly maps."
  def chat_views(state) do
    Enum.map(State.chats(state), &chat_view/1)
  end

  def chat_view(chat) do
    %{
      "id" => chat.id,
      "type" => chat.type,
      "name" => chat.name,
      "members" =>
        Enum.map(chat.members, fn member ->
          %{
            "type" => member.type,
            "name" => member.name,
            "open_id" => member.open_id,
            "user_id" => member.user_id,
            "app_id" => member.app_id
          }
        end)
    }
  end

  # -- resolution helpers -------------------------------------------------------

  defp fetch_chat(state, chat_id) do
    case State.chat(state, chat_id) do
      nil -> {:error, :chat_not_found}
      chat -> {:ok, chat}
    end
  end

  defp fetch_message(state, message_id) do
    case State.message(state, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp resolve_sender(chat, nil) do
    case Enum.find(chat.members, &(&1.type == "user")) do
      nil -> {:error, :no_user_member}
      member -> {:ok, member}
    end
  end

  defp resolve_sender(chat, key) do
    case Enum.find(
           chat.members,
           &(&1.type == "user" and key in [&1.name, &1.user_id, &1.open_id])
         ) do
      nil -> {:error, {:member_not_found, key}}
      member -> {:ok, member}
    end
  end

  # A reaction or card action operator resolves against the message's chat
  # when it is registered, and falls back to a generic persona otherwise.
  defp resolve_operator(state, message, key) do
    case State.chat(state, message.chat_id) do
      nil ->
        {:ok, %{type: "user", name: key || "Alice", user_id: "alice", open_id: "ou_open_alice"}}

      chat ->
        resolve_sender(chat, key)
    end
  end

  # -- envelope builders ---------------------------------------------------------

  defp put_body(attrs, state, _chat, %{"file" => %{"name" => name, "base64" => base64}}) do
    file_key = "file_sim_#{System.unique_integer([:positive])}"
    :ok = State.put_inbound_file(state, file_key, Base.decode64!(base64), name)

    attrs ++
      [
        message_type: "file",
        content: %{"file_key" => file_key, "file_name" => name}
      ]
  end

  defp put_body(attrs, state, _chat, %{"image" => %{"name" => name, "base64" => base64}}) do
    image_key = "img_sim_#{System.unique_integer([:positive])}"
    :ok = State.put_inbound_file(state, image_key, Base.decode64!(base64), name)

    attrs ++
      [
        message_type: "image",
        content: %{"image_key" => image_key}
      ]
  end

  defp put_body(attrs, _state, _chat, %{"message_type" => message_type, "content" => content})
       when is_binary(message_type) and is_map(content) do
    attrs ++ [message_type: message_type, content: content]
  end

  defp put_body(attrs, _state, _chat, params) do
    attrs ++ [text: params["text"] || ""]
  end

  defp put_mentions(attrs, chat, params) do
    case mention_targets(chat, params) do
      [] ->
        attrs

      bots ->
        mentions =
          bots
          |> Enum.with_index(1)
          |> Enum.map(fn {bot, index} ->
            %{
              "key" => "@_user_#{index}",
              "name" => bot.name,
              "id" => %{"open_id" => bot.open_id},
              "tenant_key" => "tenant-chaos"
            }
          end)

        keys = Enum.map_join(mentions, " ", & &1["key"])
        text = Keyword.get(attrs, :text)

        attrs
        |> Keyword.put(:mentions, mentions)
        |> then(fn attrs ->
          # The mention key must appear in the text body, as on the real
          # platform, so the adapter can strip or render it.
          case text do
            nil -> attrs
            text -> Keyword.put(attrs, :text, String.trim(keys <> " " <> text))
          end
        end)
    end
  end

  defp mention_targets(chat, params) do
    cond do
      params["mention_bot"] in [true, "true"] ->
        Enum.filter(chat.members, &(&1.type == "bot"))

      is_list(params["mentions"]) ->
        Enum.filter(chat.members, fn member ->
          member.open_id in params["mentions"] or member.name in params["mentions"]
        end)

      true ->
        []
    end
  end

  defp put_reply(attrs, state, %{"reply_to" => reply_to}) when is_binary(reply_to) do
    case State.message(state, reply_to) do
      nil -> attrs
      target -> attrs ++ [parent_id: target.id, root_id: target.root_id || target.id]
    end
  end

  defp put_reply(attrs, _state, _params), do: attrs

  defp default_sender_name(:bot), do: "bot"
  defp default_sender_name(_user), do: "user"
end
