defmodule BullX.Integration.IMGateway.MockIM do
  @moduledoc """
  Scenario DSL for driving the mock IM channel through the BullX integration path.

  Each `say/edit/recall/command` builds a provider event and pushes it through
  the *real* inbound pipeline
  (`ChannelAdapter.accept_inbound/4` → `BullX.IMGateway.accept_message_event/2`
  → `BullX.MailBox`), so coalescing, attention routing, dedupe and lifecycle
  handling all execute for real. Outbound is captured in
  `BullX.Integration.IMGateway.MockIM.Server` and read back via the transcript helpers here.

  Emitting an event does NOT run the agent — call
  `BullX.Integration.IMGateway.Case.settle/0` to advance the mailbox. This
  mirrors reality: sending an IM message and the agent reacting to it are
  separate steps.

  Conventions:

    * A user is an atom/string (`:alice` → external id `"ou_alice"`) or a
      `%{id:, display_name:}` map — a stable external id per user so repeat
      messages from the same person share a coalesce actor key.
    * In a group, the bot is only "addressed" when `mention: :bot` is passed;
      a DM is always addressed.
  """

  alias BullX.Integration.IMGateway.MockIM.Server
  alias BullX.IMGateway.ChannelAdapter

  @adapter "mock"

  # ---------------------------------------------------------------------------
  # Chats
  # ---------------------------------------------------------------------------

  @doc """
  Create a group chat. Options: `:id`, `:source_id`, `:mode`
  (`"addressed_only"` default / `"observe_all"` / `"engage_all"`), `:members`.
  """
  def new_group(opts \\ []) do
    %{
      id: opts[:id] || gen_id("group"),
      kind: :group,
      source_id: opts[:source_id] || "default",
      realm_id: opts[:realm_id],
      group_message_mode: opts[:mode] || "addressed_only",
      members: opts[:members] || []
    }
  end

  @doc "Create a direct-message chat (always addressed). Options: `:id`, `:source_id`, `:with`."
  def new_dm(opts \\ []) do
    %{
      id: opts[:id] || gen_id("dm"),
      kind: :dm,
      source_id: opts[:source_id] || "default",
      realm_id: opts[:realm_id],
      group_message_mode: "engage_all",
      members: List.wrap(opts[:with])
    }
  end

  # ---------------------------------------------------------------------------
  # Inbound emission
  # ---------------------------------------------------------------------------

  @doc """
  Send a message from `sender` in `chat`. Returns the provider message id (a ref
  usable with `edit/3`, `recall/1`). Options: `:mention` (`:bot` or a list of
  user refs), `:reply_to`, `:mode`, `:delivery_mode` (`"stream"`),
  `:message_id`, `:occurrence_id`.
  """
  def say(chat, sender, text, opts \\ []) do
    s = normalize_sender(sender)
    message_id = opts[:message_id] || gen_id("msg")
    mention_bot? = mention_bot?(opts)

    input = %{
      kind: :message,
      occurrence_id: opts[:occurrence_id] || gen_id("evt"),
      message_id: message_id,
      chat_id: chat.id,
      chat_kind: chat.kind,
      source_id: chat.source_id,
      realm_id: chat[:realm_id],
      sender: s,
      text: text,
      mention_bot: mention_bot?,
      mentions: mentions_from(opts),
      group_message_mode: opts[:mode] || chat.group_message_mode,
      reply_to: opts[:reply_to],
      delivery_mode: opts[:delivery_mode]
    }

    Server.put_message(message_id, %{
      chat: chat,
      sender: s,
      text: text,
      mention_bot: mention_bot?,
      state: :active
    })

    _result = emit_provider_input(input, allow_ignore?: Keyword.get(opts, :allow_ignore, false))
    message_id
  end

  @doc "Edit a previously-sent message. `mention: :bot | :none` toggles the @-bot state."
  def edit(message_id, new_text, opts \\ []) when is_binary(message_id) do
    msg = fetch_message!(message_id)
    mention_bot? = edited_mention(opts, msg)

    input = %{
      kind: :edit,
      occurrence_id: opts[:occurrence_id] || gen_id("evt"),
      message_id: message_id,
      chat_id: msg.chat.id,
      chat_kind: msg.chat.kind,
      source_id: msg.chat.source_id,
      realm_id: msg.chat[:realm_id],
      sender: msg.sender,
      text: new_text,
      mention_bot: mention_bot?,
      mentions: mentions_from(opts),
      group_message_mode: opts[:mode] || msg.chat.group_message_mode
    }

    Server.update_message(message_id, &%{&1 | text: new_text, mention_bot: mention_bot?})
    _result = emit_provider_input(input, allow_ignore?: Keyword.get(opts, :allow_ignore, false))
    message_id
  end

  @doc "Recall (withdraw) a previously-sent message."
  def recall(message_id, opts \\ []) when is_binary(message_id),
    do: lifecycle(message_id, :recall, opts)

  @doc "Delete a previously-sent message."
  def delete(message_id, opts \\ []) when is_binary(message_id),
    do: lifecycle(message_id, :delete, opts)

  defp lifecycle(message_id, kind, opts) do
    msg = fetch_message!(message_id)

    input = %{
      kind: kind,
      occurrence_id: opts[:occurrence_id] || gen_id("evt"),
      message_id: message_id,
      chat_id: msg.chat.id,
      chat_kind: msg.chat.kind,
      source_id: msg.chat.source_id,
      realm_id: msg.chat[:realm_id],
      sender: msg.sender,
      mention_bot: false,
      group_message_mode: msg.chat.group_message_mode
    }

    Server.update_message(message_id, &%{&1 | state: kind})
    _result = emit_provider_input(input, allow_ignore?: Keyword.get(opts, :allow_ignore, false))
    message_id
  end

  @doc "Invoke a slash command (parsed from leading slash), e.g. /undo or /compress."
  def command(chat, sender, text, _opts \\ []) do
    {name, args} = parse_command(text)
    s = normalize_sender(sender)

    input = %{
      kind: :command,
      occurrence_id: gen_id("evt"),
      message_id: gen_id("cmd"),
      chat_id: chat.id,
      chat_kind: chat.kind,
      source_id: chat.source_id,
      realm_id: chat[:realm_id],
      sender: s,
      command: %{name: name, args_text: args},
      group_message_mode: chat.group_message_mode
    }

    emit_provider_input(input)
  end

  @doc """
  Emit a raw mock provider input through the registered channel adapter.

  This is intentionally lower-level than `say/4`, `edit/3`, and `recall/2`.
  Use it for provider-ordering scenarios that cannot be represented by the
  friendly DSL, such as a lifecycle webhook arriving before the original
  receive webhook.
  """
  def emit_provider_input(%{} = input, opts \\ []) do
    do_emit(input, opts)
  end

  @doc "Shorthand for `/steer <text>` — injects a steering note into an in-flight generation."
  def steer(chat, sender, text), do: command(chat, sender, "/steer " <> text)

  @doc "Shorthand for `/undo`."
  def undo(chat, sender), do: command(chat, sender, "/undo")

  # ---------------------------------------------------------------------------
  # Outbound transcript (assertions)
  # ---------------------------------------------------------------------------

  @doc "Every outbound record (send/edit/recall/stream notice) for a chat, chronological."
  def transcript(chat), do: Server.outbound(chat.id)

  @doc "Texts of the bot's visible `send` messages in a chat."
  def bot_texts(chat),
    do: chat |> ops(["send"]) |> Enum.map(& &1.text) |> Enum.reject(&(&1 == ""))

  @doc "Text of the bot's most recent visible `send` in a chat (or nil)."
  def last_bot_text(chat), do: chat |> bot_texts() |> List.last()

  @doc "Recall operations the bot issued in a chat."
  def recalls(chat), do: ops(chat, ["recall"])

  @doc "Edit operations the bot issued in a chat."
  def edits(chat), do: ops(chat, ["edit"])

  @doc "Stream-consume records (streaming replies)."
  def streams, do: Server.streams()

  @doc "Failed delivery attempts for a chat."
  def delivery_failures(chat), do: Server.delivery_failures(chat.id)

  defp ops(chat, op_list), do: Enum.filter(transcript(chat), &(&1.op in op_list))

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_emit(input, opts) do
    source = %{"id" => input.source_id, "adapter" => @adapter, "trusted_realm_by_default" => true}
    allow_ignore? = Keyword.get(opts, :allow_ignore?, false)

    case ChannelAdapter.accept_inbound(@adapter, source, input, registry: registry()) do
      {:ok, _result} = ok ->
        ok

      :ignore when allow_ignore? ->
        :ignore

      :ignore ->
        ExUnit.Assertions.flunk("mock IM event was unexpectedly ignored: #{inspect(input)}")

      {:error, reason} ->
        ExUnit.Assertions.flunk("mock IM event was rejected: #{inspect(reason)}")
    end
  end

  defp registry do
    Application.get_env(:bullx, :im_gateway_channel_adapter_registry, BullX.Plugins.Registry)
  end

  defp fetch_message!(message_id) do
    Server.get_message(message_id) ||
      raise ArgumentError, "unknown mock message ref: #{inspect(message_id)}"
  end

  defp normalize_sender(ref) when is_atom(ref),
    do: %{id: "ou_" <> Atom.to_string(ref), display_name: Atom.to_string(ref)}

  defp normalize_sender(ref) when is_binary(ref),
    do: %{id: "ou_" <> ref, display_name: ref}

  defp normalize_sender(%{id: _id} = ref), do: Map.put_new(ref, :display_name, ref.id)

  defp mention_bot?(opts) do
    case Keyword.get(opts, :mention) do
      :bot -> true
      list when is_list(list) -> :bot in list
      _other -> false
    end
  end

  defp mentions_from(opts) do
    case Keyword.get(opts, :mention) do
      :bot -> [%{"id" => "bot", "username" => "bot"}]
      list when is_list(list) -> Enum.map(list, &mention_entry/1)
      _other -> []
    end
  end

  defp mention_entry(:bot), do: %{"id" => "bot", "username" => "bot"}
  defp mention_entry(ref) when is_atom(ref), do: %{"id" => "ou_" <> Atom.to_string(ref)}
  defp mention_entry(ref) when is_binary(ref), do: %{"id" => "ou_" <> ref}

  defp edited_mention(opts, msg) do
    case Keyword.get(opts, :mention) do
      :bot -> true
      :none -> false
      list when is_list(list) -> :bot in list
      nil -> msg.mention_bot
    end
  end

  defp parse_command(text) do
    text
    |> String.trim_leading()
    |> String.trim_leading("/")
    |> String.split(~r/\s+/, parts: 2)
    |> case do
      [name, args] -> {String.downcase(name), String.trim(args)}
      [name] -> {String.downcase(name), ""}
    end
  end

  # IMGateway dedupes inbound events by occurrence id in a cross-run cache
  # (~25h TTL). Ids must be unique within the VM (so tests in one run don't
  # collide) and across runs — `unique_integer` gives the former, a per-VM token
  # the latter.
  defp gen_id(prefix),
    do: "#{prefix}-#{run_token()}-#{System.unique_integer([:positive, :monotonic])}"

  defp run_token do
    case :persistent_term.get({__MODULE__, :run_token}, nil) do
      nil ->
        token = Integer.to_string(System.system_time(:nanosecond), 36)
        :persistent_term.put({__MODULE__, :run_token}, token)
        token

      token ->
        token
    end
  end
end
