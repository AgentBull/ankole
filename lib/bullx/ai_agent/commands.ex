defmodule BullX.AIAgent.Commands do
  @moduledoc """
  AIAgent-owned slash command catalog and Conversation-local handlers.
  """

  import Ecto.Query

  alias BullX.AIAgent.{ACL, Conversation, Conversations, DeliveryRecall, Message}
  alias BullX.Repo

  @catalog %{
    "new" => %{token: "/new", aliases: ["/新会话"], access: :ordinary},
    "compress" => %{token: "/compress", aliases: ["/压缩"], access: :ordinary},
    "retry" => %{token: "/retry", aliases: [], access: :ordinary},
    "steer" => %{token: "/steer", aliases: [], access: :ordinary},
    "stop" => %{token: "/stop", aliases: [], access: :ordinary},
    "undo" => %{token: "/undo", aliases: [], access: :ordinary}
  }

  @spec catalog() :: map()
  def catalog, do: @catalog

  @spec command_event_name(map()) :: String.t() | nil
  def command_event_name(event_data) when is_map(event_data) do
    event_data["command"]
    |> command_name()
    |> fallback_command_name(get_in(event_data, ["routing_facts", "command_name"]))
  end

  @spec command_event_args(map()) :: String.t()
  def command_event_args(event_data) when is_map(event_data) do
    case safe_argument_text(event_data) do
      text when is_binary(text) ->
        String.trim(text)

      nil ->
        ""
    end
  end

  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@catalog, name)

  @spec run(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(command_name, context) when is_binary(command_name) and is_map(context) do
    with {:ok, command} <- fetch(command_name),
         :allowed <-
           ACL.authorize(
             context.caller_principal_uid,
             context.agent_uid,
             command.access,
             Map.get(context, :acl_context, %{})
           ) do
      execute(command_name, context)
    else
      {:error, :unknown_command} -> {:ok, diagnostic(:unknown_command)}
      {:denied, _reason} -> {:ok, diagnostic(:denied)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(command_name) do
    case Map.fetch(@catalog, command_name) do
      {:ok, command} -> {:ok, command}
      :error -> {:error, :unknown_command}
    end
  end

  defp command_name(%{"name" => name}) when is_binary(name), do: normalize_name(name)
  defp command_name(%{name: name}) when is_binary(name), do: normalize_name(name)
  defp command_name(_command), do: nil

  defp fallback_command_name(name, _fallback) when is_binary(name) and name != "", do: name

  defp fallback_command_name(_name, fallback) when is_binary(fallback),
    do: normalize_name(fallback)

  defp fallback_command_name(_name, _fallback), do: nil

  defp safe_argument_text(event_data) do
    get_in(event_data, ["command_args", "text"]) ||
      get_in(event_data, ["arguments", "text"]) ||
      get_in(event_data, ["command", "args_text"])
  end

  defp normalize_name(name) do
    name
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end

  defp execute("new", context) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(context.conversation_id)

      if active_generation?(conversation, now) do
        {:ok, _cancelled} = Conversations.cancel_generation(conversation, "new_session", now)
      end

      {:ok, _closed} = Conversations.close_active(conversation, "new_session", now)

      {:ok, fresh} =
        Conversations.find_or_create_active(
          conversation.agent_uid,
          conversation.conversation_key,
          conversation.metadata
        )

      fresh
    end)
    |> case do
      {:ok, %Conversation{} = fresh} ->
        {:ok, %{status: :ok, command: "new", conversation_id: fresh.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute("compress", context) do
    case locked_inactive_conversation(context.conversation_id) do
      {:ok, conversation} ->
        feedback_ref = command_feedback(context, %{command: "compress", phase: :started})
        result = BullX.AIAgent.Compression.manual_compress(conversation, context)

        _feedback_result =
          command_feedback(context, %{
            command: "compress",
            phase: :finished,
            feedback_ref: feedback_ref,
            result: result
          })

        tag_command_result(result, "compress")

      {:error, :active_generation_present} ->
        {:ok, diagnostic(:active_generation_present)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute("retry", context) do
    case retry_with_lease(context) do
      {:ok, result} -> {:ok, result}
      {:error, :active_generation_present} -> {:ok, diagnostic(:active_generation_present)}
      {:error, :no_retry_target} -> {:ok, diagnostic(:no_retry_target)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute("steer", %{args: args}) when args in [nil, ""],
    do: {:ok, diagnostic(:missing_prompt)}

  defp execute("steer", context) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(context.conversation_id)

      case active_generation?(conversation, now) do
        true ->
          BullX.AIAgent.Steering.put(
            conversation.generation["lease_id"],
            context.trigger_id,
            context.args
          )

          %{status: :ok, command: "steer"}

        false ->
          diagnostic(:no_active_generation)
      end
    end)
    |> ok_or_error()
  end

  defp execute("stop", context) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(context.conversation_id)

      case active_generation?(conversation, now) do
        true ->
          lease_id = conversation.generation["lease_id"]

          with {:ok, cancelled} <-
                 Conversations.cancel_generation(conversation, "stop", now, %{
                   "cancelled_by_command_entry_id" => context.trigger_id
                 }),
               {:ok, recall_targets} <-
                 interrupt_generating_messages(cancelled, lease_id, context, now) do
            %{status: :ok, command: "stop", recall_targets: recall_targets}
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        false ->
          case generation_cancelled_by_command?(conversation, context) do
            true -> %{status: :ok, command: "stop", recall_targets: []}
            false -> diagnostic(:no_active_generation)
          end
      end
    end)
    |> ok_or_error()
  end

  defp execute("undo", context) do
    case undo_locked(context) do
      {:ok, %{conversation: conversation, recall_targets: recall_targets}} ->
        {:ok,
         %{
           status: :ok,
           command: "undo",
           conversation_id: conversation.id,
           recall_targets: recall_targets
         }}

      {:error, :active_generation_present} ->
        {:ok, diagnostic(:active_generation_present)}

      {:error, :no_undo_target} ->
        {:ok, diagnostic(:no_undo_target)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(_unknown, _context), do: {:ok, diagnostic(:unknown_command)}

  defp generation_cancelled_by_command?(%Conversation{} = conversation, context) do
    generation = conversation.generation || %{}

    generation["cancellation_reason"] == "stop" and
      generation["cancelled_by_command_entry_id"] == context.trigger_id
  end

  defp tag_command_result({:ok, result}, command) when is_map(result),
    do: {:ok, Map.put_new(result, :command, command)}

  defp tag_command_result(result, _command), do: result

  defp diagnostic(reason), do: %{status: :diagnostic, reason: Atom.to_string(reason)}

  defp command_feedback(context, payload) do
    case Map.get(context, :feedback_fun) do
      fun when is_function(fun, 1) -> fun.(payload)
      _missing -> nil
    end
  end

  defp ok_or_error({:ok, result}), do: {:ok, result}
  defp ok_or_error({:error, reason}), do: {:error, reason}

  defp locked_inactive_conversation(conversation_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(conversation_id)

      case active_generation?(conversation, now) do
        true -> Repo.rollback(:active_generation_present)
        false -> conversation
      end
    end)
  end

  defp lock_conversation!(conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp active_generation?(%Conversation{} = conversation, now) do
    Conversations.owned_active_lease?(
      conversation,
      conversation.generation["lease_id"] || "",
      now
    )
  end

  defp retry_with_lease(context) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(context.conversation_id)

      if active_generation?(conversation, now) do
        Repo.rollback(:active_generation_present)
      end

      with {:ok, trigger_message, retry_of_message_id} <- last_generation_trigger(conversation),
           {:ok, recall_targets} <- mark_suffix(conversation, trigger_message, "retry", context),
           {:ok, rewound} <- set_current_leaf(conversation, trigger_message.id),
           {:ok, leased, lease_id} <-
             Conversations.acquire_generation_lease_locked(
               rewound,
               generation_owner("command_retry", context.trigger_id, trigger_message.id, context),
               now
             ) do
        %{
          status: :start_generation,
          command: "retry",
          conversation_id: leased.id,
          trigger_message_id: trigger_message.id,
          retry_of_message_id: retry_of_message_id,
          lease_id: lease_id,
          recall_targets: recall_targets
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp undo_locked(context) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      conversation = lock_conversation!(context.conversation_id)

      if active_generation?(conversation, now) do
        Repo.rollback(:active_generation_present)
      end

      with {:ok, trigger_message} <- last_exchange_trigger(conversation),
           {:ok, recall_targets} <-
             mark_suffix(conversation, trigger_message, "undo", context,
               include_trigger_message?: true
             ),
           {:ok, updated} <- set_current_leaf(conversation, trigger_message.parent_id) do
        %{conversation: updated, recall_targets: recall_targets}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp last_generation_trigger(%Conversation{} = conversation) do
    branch = Conversations.render_branch(conversation)
    indexed = Map.new(branch, &{&1.id, &1})

    case List.last(branch) do
      %Message{} = tail when tail.role in [:user, :im_ambient] ->
        case user_like_trigger_message?(tail) do
          true -> {:ok, tail, tail.id}
          false -> {:error, :no_retry_target}
        end

      %Message{} = tail ->
        last_generated_trigger(tail, branch, indexed)

      _tail ->
        {:error, :no_retry_target}
    end
  end

  defp last_generated_trigger(tail, branch, indexed) do
    case retry_tail?(tail) do
      true ->
        branch
        |> Enum.reverse()
        |> Enum.find(fn
          %Message{role: :assistant, kind: :normal, status: :complete} -> true
          %Message{role: :assistant, kind: :error, status: :complete} -> true
          _message -> false
        end)
        |> generation_trigger(indexed)

      false ->
        {:error, :no_retry_target}
    end
  end

  defp generation_trigger(
         %Message{
           id: retry_of_message_id,
           metadata: %{"generation" => %{"trigger_message_id" => trigger_message_id}}
         },
         indexed
       ) do
    case Map.get(indexed, trigger_message_id) do
      %Message{} = message ->
        case user_like_trigger_message?(message) do
          true -> {:ok, message, retry_of_message_id}
          false -> {:error, :no_retry_target}
        end

      nil ->
        {:error, :no_retry_target}
    end
  end

  defp generation_trigger(_message, _indexed), do: {:error, :no_retry_target}

  defp user_like_trigger_message?(%Message{role: :user, kind: :normal}), do: true
  defp user_like_trigger_message?(%Message{role: :im_ambient, kind: :introspection}), do: true
  defp user_like_trigger_message?(_message), do: false

  defp retry_tail?(%Message{role: :assistant, kind: :normal, status: :complete}), do: true
  defp retry_tail?(%Message{role: :assistant, kind: :error, status: :complete}), do: true
  defp retry_tail?(%Message{role: :tool, kind: :normal, status: :complete}), do: true
  defp retry_tail?(_message), do: false

  defp last_exchange_trigger(%Conversation{} = conversation) do
    conversation
    |> Conversations.render_branch()
    |> Enum.reverse()
    |> Enum.find(&user_like_trigger_message?/1)
    |> case do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :no_undo_target}
    end
  end

  defp set_current_leaf(conversation, message_id) do
    conversation
    |> Conversation.changeset(%{current_leaf_message_id: message_id})
    |> Repo.update()
  end

  defp mark_suffix(conversation, trigger_message, command, context, opts \\ []) do
    include_trigger_message? = Keyword.get(opts, :include_trigger_message?, false)

    messages =
      conversation
      |> Conversations.active_branch()
      |> Enum.drop_while(&(&1.id != trigger_message.id))
      |> maybe_drop_trigger_message(include_trigger_message?)

    recall_targets = delivery_recall_targets(messages)

    messages
    |> Enum.reduce_while(:ok, fn message, :ok ->
      metadata =
        Map.put(message.metadata, "branch_effect", %{
          "state" => branch_state(command),
          "command" => command,
          "command_entry_id" => context.trigger_id,
          "at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond))
        })

      case Conversations.update_message(message, %{metadata: metadata}) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, recall_targets}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interrupt_generating_messages(conversation, lease_id, context, now) do
    messages =
      Message
      |> where([m], m.conversation_id == ^conversation.id)
      |> where([m], m.role == :assistant and m.kind == :normal and m.status == :generating)
      |> where([m], fragment("?->'generation'->>'lease_id' = ?", m.metadata, ^lease_id))
      |> Repo.all()

    recall_targets = delivery_recall_targets(messages)

    messages
    |> Enum.reduce_while(:ok, fn message, :ok ->
      metadata =
        message.metadata
        |> Map.put("branch_effect", %{
          "state" => "interrupted",
          "command" => "stop",
          "command_entry_id" => context.trigger_id,
          "at" => DateTime.to_iso8601(now)
        })
        |> put_in(["stream", "status"], "interrupted")

      attrs = %{
        role: :assistant,
        kind: :error,
        status: :complete,
        content: [Message.error_block("generation_stopped", "AIAgent generation stopped.", true)],
        metadata: metadata
      }

      case Conversations.update_message(message, attrs) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, recall_targets}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_recall_targets(messages) do
    DeliveryRecall.targets_for_messages(messages)
  end

  defp maybe_drop_trigger_message(messages, true), do: messages
  defp maybe_drop_trigger_message([_trigger_message | rest], false), do: rest
  defp maybe_drop_trigger_message([], _include_trigger_message?), do: []

  defp branch_state("retry"), do: "superseded"
  defp branch_state("undo"), do: "undone"
  defp branch_state(_command), do: "interrupted"

  defp generation_owner(owner_trigger_type, owner_trigger_id, trigger_message_id, context) do
    generation = context.profile.generation

    %{
      "owner_trigger_type" => owner_trigger_type,
      "owner_trigger_id" => owner_trigger_id,
      "trigger_message_id" => trigger_message_id,
      "generation_lease_ttl_ms" => generation.generation_lease_ttl_ms,
      "generation_heartbeat_interval_ms" => generation.generation_heartbeat_interval_ms,
      "generation_max_runtime_ms" => generation.generation_max_runtime_ms
    }
  end
end
