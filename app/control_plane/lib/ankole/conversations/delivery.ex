defmodule Ankole.Conversations.Delivery do
  import Ankole.Attrs, only: [collect_results: 1]

  @moduledoc """
  Commits provider delivery intents and dispatches them through their Binding.

  Commit operations record durable effects and wakeup jobs in the caller's
  transaction. Dispatch performs provider IO after commit and records the
  result for retry or operator recovery. Each target keeps its own route and
  idempotency key. Preview and interaction checkpoints remain separate owners.
  See `docs/design-docs/Signals.md` for the delivery and recovery contracts.
  """

  import Ecto.Query, warn: false

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Signals.Signal
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.Text
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.Attachment
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Conversation

  # Give a transient provider failure a short recovery window before retry.
  @doc """
  Records a provider-visible intent intent committed by the actor runtime.

  This is the "commit" half of the intent: the actor declares it wants to do
  something to the provider, transactionally, without performing it yet. The
  `on_conflict: :nothing` upsert on `{agent_uid, binding_name, outbound_key}` is
  the idempotency contract — committing the same `outbound_key` twice yields the
  same single row (and therefore at most one provider side effect).
  Delivery uses durable Oban jobs and `dispatch`.
  """
  @spec commit(map()) :: {:ok, Intent.t()} | {:error, term()}
  def commit(attrs) when is_map(attrs) do
    Repo.transact(fn repo -> commit_in_tx(repo, attrs) end)
  end

  @doc """
  Records a provider-visible intent intent inside a caller-owned transaction.
  """
  @spec commit_in_tx(module(), map()) :: {:ok, Intent.t()} | {:error, term()}
  def commit_in_tx(repo, attrs) when is_map(attrs) do
    with :ok <- verify_attachment_destination(attrs),
         {:ok, %Intent{} = intent} <-
           %Intent{}
           |> Intent.changeset(default_intent_attrs(attrs))
           |> repo.insert(
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :binding_name, :outbound_key],
             returning: true
           )
           |> intent_insert_result(repo, attrs),
         :ok <- reference_attachments(repo, intent),
         :ok <- Ankole.Conversations.Delivery.Recovery.notify_intent_deadline(repo, intent) do
      {:ok, intent}
    end
  end

  defp verify_attachment_destination(attrs) do
    payload = attrs[:payload] || %{}
    conversation_id = attrs[:conversation_id]

    Enum.reduce_while(payload["attachments"] || [], :ok, fn attachment, :ok ->
      case Ankole.Files.verify_delivery(attachment["path"] || "", conversation_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reference_attachments(_repo, %Intent{status: :sent}), do: :ok

  defp reference_attachments(repo, %Intent{payload: payload}) do
    references =
      payload
      |> Map.get("attachments", [])
      |> Enum.flat_map(fn
        %{"blob_ref" => reference} -> [reference]
        _legacy_attachment -> []
      end)

    Ankole.Files.reference_contents_in_tx(repo, references)
  end

  @doc """
  Commits reply-attachment effects adopted by an explicit Agent Turn completion.

  The attachment row carries no visible text: no adapter renders a caption next
  to an uploaded file, and the final reply already delivers the answer. Giving
  the attachment its own copy of that text posted the same wall twice into the
  conversation mirror the agent reads back.
  """
  @spec commit_reply_attachments_in_tx(
          module(),
          Signal.t(),
          binary(),
          [map()],
          keyword()
        ) :: {:ok, [Intent.t()]} | {:error, term()}
  def commit_reply_attachments_in_tx(
        repo,
        %Signal{} = signal,
        ai_message_id,
        attachments,
        opts \\ []
      )
      when is_binary(ai_message_id) and is_list(attachments) do
    with {:ok, attachments} <- Attachment.normalize_attachments(attachments),
         :ok <- Attachment.verify_in_drive(signal.agent_uid, attachments) do
      for target <- reply_targets(signal, opts),
          {attachment, index} <- Enum.with_index(attachments) do
        commit_reply_attachment_intent_in_tx(
          repo,
          signal,
          ai_message_id,
          target,
          attachment,
          index,
          opts
        )
      end
      |> collect_results()
    end
  end

  @doc """
  Reads the bytes of one intent attachment.

  The attachment names its content by `blob_ref`, so the bytes are the ones the
  Agent attached. `{:error, :attachment_file_missing}` means that the content is
  missing or unreadable. Uncompleted Delivery references normally prevent
  collection even when the drive path is removed.
  An adapter returns that error as it is, and the intent blocks the delivery
  instead of retrying it.
  """
  @spec attachment_content(map()) :: {:ok, binary()} | {:error, term()}
  def attachment_content(%{"blob_ref" => blob_ref}) when is_binary(blob_ref) do
    case Ankole.Files.read_content(blob_ref) do
      {:ok, content} -> {:ok, content}
      {:error, :not_found} -> {:error, :attachment_file_missing}
      {:error, {:invalid_sha256, _value}} -> {:error, :attachment_file_missing}
      {:error, _reason} = error -> error
    end
  end

  def attachment_content(_attachment), do: {:error, :attachment_file_missing}

  @doc """
  Commits the durable final replies adopted by an explicit Agent Turn completion.
  """
  @spec commit_final_reply_in_tx(
          module(),
          Signal.t(),
          Message.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, [Intent.t()]} | {:error, term()}
  def commit_final_reply_in_tx(
        repo,
        %Signal{} = signal,
        %Message{} = message,
        text,
        opts \\ []
      ) do
    case normalize_visible_text(text) do
      "" ->
        {:ok, []}

      final_text ->
        signal
        |> reply_targets(opts)
        |> Enum.map(
          &commit_final_reply_intent_in_tx(
            repo,
            signal,
            message,
            final_text,
            &1,
            opts
          )
        )
        |> collect_results()
    end
  end

  @doc false
  @spec commit_clarify_reply_in_tx(
          module(),
          Signal.t(),
          Message.t(),
          String.t(),
          map(),
          keyword()
        ) :: {:ok, Intent.t()} | {:error, term()}
  def commit_clarify_reply_in_tx(
        repo,
        %Signal{} = signal,
        %Message{} = message,
        text,
        interactive_output,
        opts \\ []
      )
      when is_binary(text) and is_map(interactive_output) do
    target = Keyword.get(opts, :delivery_target, default_reply_target(signal))
    signal = routed_signal(signal, target)

    with {:ok, operation, operation_attrs} <-
           final_reply_operation(repo, signal) do
      outbound_key = "ai-reply:#{message.id}"

      commit_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: signal.agent_uid,
            binding_name: signal.reply_binding_name,
            outbound_key: outbound_key,
            operation: operation,
            conversation_id: signal.conversation_id,
            provider_thread_id: signal.provider_thread_id,
            source_signal_id: signal.id,
            ai_message_id: message.id,
            delivery_class: :durable_ai_reply,
            payload: %{
              "text" => text,
              "interactive_output" => interactive_output,
              "reply_presentation" =>
                clarify_reply_presentation(signal, text, interactive_output),
              "metadata" => %{
                "ai_message_id" => message.id,
                "signal_id" => signal.id,
                "source" => "ai_gateway_clarify",
                "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
              }
            },
            fallback_visible_text: text,
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  @doc false
  def commit_notice_in_tx(
        repo,
        %Signal{} = signal,
        text,
        %{
          prefix: outbound_key_prefix,
          empty_error: empty_text_error,
          metadata: metadata,
          state: terminal_state
        },
        opts \\ []
      ) do
    case normalize_visible_text(text) do
      "" ->
        {:error, empty_text_error}

      final_text ->
        target = Keyword.get(opts, :delivery_target, default_reply_target(signal))
        routed = routed_signal(signal, target)

        with {:ok, operation, operation_attrs} <-
               final_reply_operation_for_target(repo, routed, target) do
          outbound_key =
            "#{outbound_key_prefix}:#{signal.id}" <>
              if(target.key, do: ":#{target.key}", else: "")

          commit_in_tx(
            repo,
            Map.merge(
              %{
                agent_uid: signal.agent_uid,
                binding_name: routed.reply_binding_name,
                outbound_key: outbound_key,
                operation: operation,
                conversation_id: routed.conversation_id,
                provider_thread_id: routed.provider_thread_id,
                source_signal_id: signal.id,
                delivery_class: :durable_ai_reply,
                payload: %{
                  "text" => final_text,
                  "reply_presentation" =>
                    session_notice_reply_presentation(
                      routed,
                      terminal_state,
                      final_text,
                      metadata
                    ),
                  "metadata" => reply_metadata(target, Map.put(metadata, "signal_id", signal.id))
                },
                fallback_visible_text: final_text,
                idempotency_key: outbound_key
              },
              operation_attrs
            )
          )
        end
    end
  end

  defp session_notice_reply_presentation(_signal, "stopped", text, %{
         "reason" => "context_withdrawn"
       }),
       do: ReplyPresentation.new() |> ReplyPresentation.terminal("stopped", text)

  defp session_notice_reply_presentation(signal, "stopped", _fallback_text, _metadata) do
    presentation = reply_presentation_checkpoint(signal) |> ReplyPresentation.normalize()
    partial_answer = presentation["answer"] || ""

    presentation
    |> ReplyPresentation.terminal("stopped", partial_answer)
    |> Map.put("answer", partial_answer)
  end

  defp session_notice_reply_presentation(signal, terminal_state, text, _metadata),
    do: terminal_reply_presentation(signal, terminal_state, text)

  @doc """
  Chooses the provider-visible reply operation for an Signal.

  Decides whether the agent's reply should be a threaded `:reply` to the
  triggering entry or a top-level `:post`, from the durable route rows alone:
  the conversation's reply_mode and the entry the event arrived on. Missing route
  state is returned as an error so a provider-visible side effect is never
  committed to an invented route.

  Whether the bound adapter can perform that operation is deliberately not asked
  here. Adapter availability is live process state, so a commit that consulted
  it failed the whole caller transaction whenever a plugin was absent — which
  let one old event block worker takeover and turn cleanup. `dispatch`
  owns that question under the row lock, where it can also degrade an operation
  the adapter cannot perform.
  """
  @spec operation_for_signal(Signal.t(), module()) ::
          {:ok, atom()} | {:error, term()}
  def operation_for_signal(%Signal{} = signal, repo \\ Repo) do
    with {:ok, conversation} <- intent_route_channel(repo, signal),
         {:ok, _binding} <- intent_route_binding(repo, signal) do
      choose_intent_operation(conversation, signal)
    end
  end

  @doc """
  Returns true when an error means this route can never accept a message.

  A conversation that accepts no replies, and a deleted conversation or binding row, are
  durable facts of the route, not delivery failures a later attempt can clear.
  A caller that owns a durable decision — completing a Turn, or dead-lettering
  one — records that decision and skips the provider-visible intent. Failing
  instead would roll back work that already happened.
  """
  @spec unroutable_reply_reason?(term()) :: boolean()
  def unroutable_reply_reason?(:intent_reply_not_supported), do: true
  def unroutable_reply_reason?({:signal_channel_not_found, _channel_id}), do: true
  def unroutable_reply_reason?({:signal_binding_not_found, _agent_uid, _binding_name}), do: true
  def unroutable_reply_reason?(_reason), do: false

  @doc """
  Returns the operation a bound adapter can actually perform.

  Only threaded replies degrade: a conversation that wants a threaded reply still
  gets its message out as a top-level post when the adapter cannot thread. An
  adapter that can do neither keeps the requested operation, so dispatch records
  the row as `:unsupported` instead of silently sending something else.
  """
  @spec effective_operation(atom(), MapSet.t(atom())) :: atom()
  def effective_operation(:reply, capabilities) do
    cond do
      MapSet.member?(capabilities, :reply_entry) -> :reply
      MapSet.member?(capabilities, :post_entry) -> :post
      true -> :reply
    end
  end

  def effective_operation(operation, _capabilities), do: operation

  defp default_intent_attrs(attrs) do
    attrs
    |> Map.put_new(:status, :pending)
    |> Map.put_new(:delivery_class, :generic)
    |> Map.put_new(:payload, %{})
    |> Map.put_new(:attempt_count, 0)
    |> Map.put_new(:max_attempts, 10)
    |> Map.put_new(:last_error, %{})
    |> Map.put_new(:recovery_state, %{})
    |> normalize_agent_uid_attr()
  end

  # With explicit primary keys, a skipped insert may return the requested
  # values. Read the committed intent so retries adopt its payload and status.
  defp intent_insert_result({:ok, %Intent{}}, repo, attrs) do
    attrs = default_intent_attrs(attrs)

    case repo.get_by(Intent,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           outbound_key: attrs.outbound_key
         ) do
      %Intent{} = entry -> {:ok, entry}
      nil -> {:error, :intent_entry_not_found}
    end
  end

  defp intent_insert_result({:error, _changeset} = error, _repo, _attrs), do: error

  defp commit_reply_attachment_intent_in_tx(
         repo,
         %Signal{} = signal,
         ai_message_id,
         target,
         attachment,
         index,
         opts
       ) do
    routed_event = routed_signal(signal, target)

    with {:ok, operation, operation_attrs} <-
           reply_attachment_operation(repo, routed_event, target) do
      outbound_key = reply_attachment_outbound_key(ai_message_id, target, index)

      commit_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: routed_event.agent_uid,
            binding_name: routed_event.reply_binding_name,
            outbound_key: outbound_key,
            operation: operation,
            conversation_id: routed_event.conversation_id,
            provider_thread_id: routed_event.provider_thread_id,
            reply_to_provider_message_id: Signal.reply_anchor_provider_message_id(routed_event),
            # Source table: source_signal_id stores the signals.id that
            # caused this provider-visible side effect.
            source_signal_id: signal.id,
            ai_message_id: ai_message_id,
            delivery_class: :durable_ai_reply,
            payload: %{
              "attachments" => [attachment],
              "metadata" =>
                reply_metadata(target, %{
                  "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
                })
            },
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  defp commit_final_reply_intent_in_tx(
         repo,
         %Signal{} = signal,
         %Message{} = message,
         final_text,
         target,
         opts
       ) do
    routed_event = routed_signal(signal, target)

    with {:ok, operation, operation_attrs} <-
           final_reply_operation_for_target(repo, routed_event, target) do
      outbound_key = final_reply_outbound_key(message.id, target)

      payload = %{
        "text" => final_text,
        "metadata" =>
          reply_metadata(target, %{
            "ai_message_id" => message.id,
            "signal_id" => signal.id,
            "source" => "ai_gateway_final_reply",
            "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
          })
      }

      payload = maybe_put_reply_presentation(payload, routed_event, target, final_text, opts)

      commit_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: routed_event.agent_uid,
            binding_name: routed_event.reply_binding_name,
            outbound_key: outbound_key,
            operation: operation,
            conversation_id: routed_event.conversation_id,
            provider_thread_id: routed_event.provider_thread_id,
            source_signal_id: signal.id,
            ai_message_id: message.id,
            delivery_class: :durable_ai_reply,
            payload: payload,
            fallback_visible_text: final_text,
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  defp reply_targets(signal, opts) do
    Keyword.get(opts, :delivery_targets, [default_reply_target(signal)])
  end

  defp default_reply_target(signal) do
    %{
      binding_name: signal.reply_binding_name,
      conversation_id: signal.conversation_id,
      provider_thread_id: signal.provider_thread_id,
      primary: true,
      key: nil
    }
  end

  defp routed_signal(signal, target) do
    routed = %{
      signal
      | reply_binding_name: target.binding_name,
        conversation_id: target.conversation_id,
        provider_thread_id: target.provider_thread_id
    }

    if target.primary do
      routed
    else
      %{
        routed
        | provider_message_id: nil,
          ambient_asked_message_id: nil,
          preview: %PreviewState{provider_message_id: nil}
      }
    end
  end

  # Every target resolves its own route through the same reader. The caller
  # already projected the target onto `routed_event`, so a single default target
  # is the one-element case of the same rule rather than a separate path.
  defp reply_attachment_operation(repo, routed_event, %{key: nil}) do
    with {:ok, operation} <- operation_for_signal(routed_event, repo) do
      {:ok, operation, %{}}
    end
  end

  defp reply_attachment_operation(repo, routed_event, %{key: key}) when is_binary(key) do
    case operation_for_signal(routed_event, repo) do
      {:ok, operation} -> {:ok, operation, %{}}
      {:error, reason} -> unroutable_target_operation(reason, :post)
    end
  end

  defp final_reply_operation_for_target(repo, routed_event, %{key: nil}),
    do: final_reply_operation(repo, routed_event)

  defp final_reply_operation_for_target(repo, routed_event, %{key: key}) when is_binary(key) do
    case final_reply_operation(repo, routed_event) do
      {:ok, _operation, _attrs} = operation -> operation
      {:error, reason} -> unroutable_target_operation(reason, :post)
    end
  end

  # A cron target is an independent delivery intent, so one unreachable route
  # must not cancel the others. The target is still recorded, as a terminal
  # `:unsupported` row, because a deleted conversation or binding is a durable fact of
  # the route. An operator then sees a route that can never accept this reply
  # instead of a row that waits for a retry that can never help.
  defp unroutable_target_operation(reason, operation) do
    if unroutable_reply_reason?(reason) do
      {:ok, operation,
       %{
         status: :failed,
         recovery_state: %{"state" => "permanent", "reason" => "unroutable_reply_route"},
         last_error: %{
           "code" => "unroutable_reply_route",
           "reason" => inspect(reason, limit: 20)
         }
       }}
    else
      {:error, reason}
    end
  end

  defp final_reply_outbound_key(message_id, %{key: nil}), do: "ai-reply:#{message_id}"

  defp final_reply_outbound_key(message_id, %{key: key}),
    do: "ai-reply:#{message_id}:#{key}"

  defp reply_attachment_outbound_key(message_id, %{key: nil}, index),
    do: "ai-reply-attachment:#{message_id}:#{index}"

  defp reply_attachment_outbound_key(message_id, %{key: key}, index),
    do: "ai-reply-attachment:#{message_id}:#{key}:#{index}"

  defp reply_metadata(%{key: nil}, metadata), do: metadata

  defp reply_metadata(target, metadata) do
    Map.put(metadata, "delivery_target", %{
      "binding_name" => target.binding_name,
      "conversation_id" => target.conversation_id,
      "provider_thread_id" => target.provider_thread_id,
      "primary" => target.primary,
      "key" => target.key
    })
  end

  defp maybe_put_reply_presentation(payload, signal, %{primary: true}, text, opts) do
    Map.put(
      payload,
      "reply_presentation",
      terminal_reply_presentation(signal, "completed", text,
        attachment_count: Keyword.get(opts, :attachment_count, 0)
      )
    )
  end

  defp maybe_put_reply_presentation(payload, _signal, _target, _text, _opts), do: payload

  # A committed final reply reuses the streaming preview message when one was
  # established: editing it in place turns the transient preview into the durable
  # reply. Without a preview it posts a fresh threaded reply or top-level message.
  # The same operation selection serves any Signal terminal state, so a
  # dead-letter notice finalizes the preview exactly like a successful reply.
  defp final_reply_operation(repo, %Signal{} = signal) do
    case PreviewState.get(signal).provider_message_id do
      provider_message_id when is_binary(provider_message_id) ->
        {:ok, :edit, %{target_provider_message_id: provider_message_id}}

      nil ->
        with {:ok, operation} <- operation_for_signal(signal, repo) do
          attrs =
            if operation == :reply do
              %{reply_to_provider_message_id: Signal.reply_anchor_provider_message_id(signal)}
            else
              %{}
            end

          {:ok, operation, attrs}
        end
    end
  end

  def normalize_visible_text(text), do: Text.normalize_visible_text(text)

  defp terminal_reply_presentation(%Signal{} = signal, state, text, opts \\ []) do
    presentation =
      signal
      |> reply_presentation_checkpoint()
      |> ReplyPresentation.terminal(state, text)

    case Keyword.get(opts, :attachment_count, 0) do
      count when is_integer(count) and count > 0 ->
        put_in(presentation, ["meta", "attachment_count"], count)

      _count ->
        presentation
    end
  end

  defp clarify_reply_presentation(signal, text, interactive_output) do
    card_visible_text = Map.get(interactive_output, "body") || text

    signal
    |> terminal_reply_presentation("awaiting_input", card_visible_text)
    |> ReplyPresentation.interaction_request(signal.id, interactive_output)
  end

  def reply_presentation_checkpoint(%Signal{} = signal) do
    presentation =
      case PreviewState.get(signal).checkpoint do
        %{"presentation" => presentation} when is_map(presentation) -> presentation
        _checkpoint -> ReplyPresentation.new()
      end

    ReplyPresentation.project_trigger(presentation, signal.type, Signal.envelope(signal))
  end

  # Channel wants threaded replies and we have an entry to thread under.
  defp choose_intent_operation(
         %Conversation{reply_mode: :entry},
         %Signal{provider_message_id: provider_message_id}
       )
       when is_binary(provider_message_id),
       do: {:ok, :reply}

  defp choose_intent_operation(%Conversation{reply_mode: mode}, _signal)
       when mode in [:channel, :entry],
       do: {:ok, :post}

  defp choose_intent_operation(%Conversation{reply_mode: :none}, _signal),
    do: {:error, :intent_reply_not_supported}

  defp intent_route_channel(_repo, %Signal{conversation_id: nil}),
    do: {:error, :conversation_id_missing}

  defp intent_route_channel(repo, %Signal{conversation_id: conversation_id}) do
    case repo.get_by(Conversation, id: conversation_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, {:signal_channel_not_found, conversation_id}}
    end
  end

  defp intent_route_binding(repo, %Signal{} = signal) do
    case repo.get_by(Binding,
           agent_uid: signal.agent_uid,
           name: signal.reply_binding_name
         ) do
      %Binding{} = binding ->
        {:ok, binding}

      nil ->
        {:error, {:signal_binding_not_found, signal.agent_uid, signal.reply_binding_name}}
    end
  end

  defp normalize_agent_uid_attr(%{agent_uid: agent_uid} = attrs) when is_binary(agent_uid) do
    %{attrs | agent_uid: Ankole.PrincipalKey.canonicalize(agent_uid)}
  end

  defp normalize_agent_uid_attr(attrs), do: attrs

  defdelegate reconcile_wakeups(arg1 \\ DateTime.utc_now(:microsecond)),
    to: Ankole.Conversations.Delivery.Dispatch

  defdelegate dispatch(arg1, arg2, arg3, arg4, arg5 \\ []),
    to: Ankole.Conversations.Delivery.Dispatch

  defdelegate dispatch_by_key(arg1, arg2, arg3, arg4 \\ []),
    to: Ankole.Conversations.Delivery.Dispatch

  defdelegate in_flight_recovery_seconds(), to: Ankole.Conversations.Delivery.Recovery
  defdelegate requeueable?(arg1), to: Ankole.Conversations.Delivery.Recovery
  defdelegate requeue(arg1, arg2, arg3, arg4 \\ []), to: Ankole.Conversations.Delivery.Recovery
  defdelegate wake_blocked_for_binding(arg1, arg2), to: Ankole.Conversations.Delivery.Recovery

  defdelegate resolve_durable_reply_signal_in_tx(arg1, arg2, arg3, arg4, arg5),
    to: Ankole.Conversations.Delivery.Queries

  defdelegate durable_reply_surface_exists_in_tx?(arg1, arg2, arg3, arg4, arg5),
    to: Ankole.Conversations.Delivery.Queries

  defdelegate list_stopped_deliveries(arg1 \\ nil), to: Ankole.Conversations.Delivery.Queries
end
