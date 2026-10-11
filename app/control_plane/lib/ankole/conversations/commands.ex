defmodule Ankole.Conversations.Commands do
  @moduledoc """
  Applies conversation commands through their existing domain owners.

  Commands consume durable input. Writes that interrupt an active Run use
  its epoch. A retry retains tool records when the visible suffix contains
  tool calls or results.
  """
  import Ecto.Query
  alias Ankole.{AIGateway, I18n, Repo, SignalsGateway}
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Conversations.{Fence, Run}
  alias Ankole.SignalsGateway.{ActorEvent, Actors, AIGatewayLink, AIReplyPreview, Entry}

  alias Ankole.SignalsGateway.ActorRuntime.{
    EntryLifecycle,
    ReplyDeletion,
    SessionReset,
    TurnRetry
  }

  @spec route(ActorEvent.t()) :: :run | :control
  def route(%{type: "command.steer", last_attempt_at: %DateTime{}}), do: :run

  def route(%{type: type} = event) do
    cond do
      type in [
        "session.reset_due",
        "signal.entry.removed",
        "command.stop",
        "command.retry",
        "command.compress",
        "command.llm_help"
      ] ->
        :control

      type in ["command.new", "command.steer"] and command_args(event) == "" ->
        :control

      type == "command.llm" and is_nil(profile(event)) ->
        :control

      true ->
        :run
    end
  end

  @spec injectable?(ActorEvent.t()) :: boolean()
  def injectable?(%{type: "command.retry", last_attempt_at: %DateTime{}} = event),
    do: retry_target(event) == :bare

  def injectable?(event),
    do:
      route(event) == :run and
        event.type in ["command.steer", "im.message.addressed", "input.revised"]

  @spec profile(ActorEvent.t()) :: String.t() | nil
  def profile(%{payload: payload}),
    do: get_in(payload || %{}, ["data", "command", "modelProfile"])

  @spec prepare_new_in_tx(module(), ActorEvent.t(), DateTime.t()) :: :ok | {:error, term()}
  def prepare_new_in_tx(repo, %{type: "command.new", last_attempt_at: nil} = event, now) do
    with {:ok, _} <-
           AIGateway.end_active_conversation_in_tx(repo, event.agent_uid, event.session_id, now),
         do: :ok
  end

  def prepare_new_in_tx(_repo, _event, _now), do: :ok

  @spec process(map(), ActorEvent.t()) :: {:ok, map()} | {:error, term()}
  def process(key, event) do
    case Ankole.Conversations.Admission.authorize_event(event) do
      {:ok, %{input_state: "open"} = event} -> process_authorized(key, event)
      {:ok, event} -> {:ok, %{status: :dead_letter, actor_event: event}}
      error -> error
    end
  end

  defp process_authorized(key, %{type: "session.reset_due"} = event),
    do: SessionReset.process_due(key, event, [])

  defp process_authorized(_key, %{type: "signal.entry.removed"} = event),
    do: EntryLifecycle.process(event, [])

  defp process_authorized(key, %{type: "command.compress"} = event), do: compress(key, event)

  defp process_authorized(key, event) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with :ok <- Actors.lock_actor_session_in_tx(repo, key.agent_uid, key.session_id),
           %ActorEvent{completed_at: nil, input_state: "open"} = current <-
             Actors.lock_actor_event_in_tx(repo, event.id) do
        apply_command(repo, key, current, now)
      else
        _ -> {:ok, :already_consumed}
      end
    end)
  end

  @spec interrupt(Run.t(), ActorEvent.t()) :: {:ok, map()} | {:error, term()}
  def interrupt(run, %{type: "input.revised"} = event),
    do: Ankole.Conversations.Revisions.apply(run, event)

  def interrupt(run, %{type: "command.retry"} = event) do
    if retry_target(event) == :bare,
      do: retry_current(run, event),
      else: stop_and_process(run, event)
  end

  def interrupt(run, event), do: stop_and_process(run, event)

  @spec retry_action(Run.t(), ActorEvent.t()) :: {:ok, :interrupt | :continue} | {:error, term()}
  def retry_action(run, event) do
    if retry_target(event) == :bare do
      {:ok, if(event.last_attempt_at, do: :continue, else: :interrupt)}
    else
      Repo.transact(fn repo ->
        with :ok <- Actors.lock_actor_session_in_tx(repo, run.agent_uid, run.session_id),
             :ok <- Fence.check_in_tx(repo, run),
             %ActorEvent{completed_at: nil, input_state: "open"} = current <-
               Actors.lock_actor_event_in_tx(repo, event.id) do
          retry_target_action_in_tx(repo, run, current)
        else
          nil -> {:ok, :continue}
          %ActorEvent{} -> {:ok, :continue}
          error -> error
        end
      end)
    end
  end

  defp retry_target_action_in_tx(repo, run, current) do
    case retry_target(current) do
      {:target, id} ->
        case retry_source_in_tx(repo, run, current, id) do
          {:ok, %ActorEvent{}} ->
            {:ok, :interrupt}

          {:ok, :target_unavailable} ->
            with {:ok, _} <-
                   consume_retry_target_unavailable(
                     repo,
                     current,
                     DateTime.utc_now(:microsecond)
                   ),
                 do: {:ok, :continue}
        end

      _unresolved ->
        with {:ok, _} <-
               consume_retry_target_required(repo, current, DateTime.utc_now(:microsecond)),
             do: {:ok, :continue}
    end
  end

  defp retry_current(run, event) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with :ok <- Fence.check_in_tx(repo, run),
           {:ok, _} <-
             AIGatewayLink.retract_generating_turn_in_tx(
               repo,
               run,
               run.actor_event_id,
               now,
               "command.retry"
             ),
           # The model can commit a call before its terminal message arrives.
           {:ok, {_state, run}} <- Run.restore(run),
           {:ok, {run, _}} <- Run.record_pending_in_tx(repo, run),
           {:ok, history} <-
             AIGatewayLink.retract_visible_turn_suffix_in_tx(
               repo,
               run.agent_uid,
               run.session_id,
               run.actor_event_id,
               now,
               preserve_tool_history: true
             ) do
        if history.status == :preserved do
          with {:ok, _} <- repo.update(ActorEvent.changeset(event, %{last_attempt_at: now})) do
            {:ok, Run.reset(run)}
          end
        else
          with {:ok, _} <-
                 Actors.complete_command_event_in_tx(repo, event,
                   completed_at: now,
                   outbox_intents: []
                 ) do
            repo.update_all(
              from(e in ActorEvent, where: e.id in ^[run.actor_event_id | run.steer_event_ids]),
              set: [
                attempt_count: 0,
                provider_capacity_attempt_count: 0,
                last_attempt_at: nil,
                available_at: now
              ]
            )

            {:ok, :retry}
          end
        end
      end
    end)
  end

  defp stop_and_process(run, event) do
    with {:ok, %{reply_event: reply_event}} <- Run.finalize(run, "stopped") do
      settle_stopped_preview(reply_event, event)
      if route(event) == :run, do: {:ok, :restart}, else: process(run, event)
    end
  end

  # A provider-visible preview card shows the stop instead of its working
  # state. The edit is presentation only; a failure leaves the stop done.
  defp settle_stopped_preview(reply_event, command) do
    with %ActorEvent{reply_preview_source_entry_id: id} = event when is_binary(id) <-
           Repo.get(ActorEvent, reply_event.id),
         {:error, reason} <-
           SignalsGateway.Outbox.commit_stopped_turn_notice_outbox(
             event,
             I18n.t("signals_gateway.reply.command_stopped"),
             command.type
           ) do
      Ankole.Logging.warning(
        "conversations.commands.stopped_preview_not_committed",
        "stopped preview card not committed",
        %{actor_event_id: event.id, reason: inspect(reason, limit: 20)}
      )
    end
  end

  def workflow_failure(run, failure) do
    Repo.transact(fn repo ->
      with :ok <- Fence.check_in_tx(repo, run),
           {:ok, result} <-
             Ankole.Workflow.submit_result_in_tx(
               repo,
               run.spec.request_context["call_id"],
               run.agent_uid,
               run.session_id,
               failure
             ),
           do: {:ok, result}
    end)
    |> Ankole.Workflow.cleanup_terminal_transition()
  end

  def workflow_error(run, error) do
    Repo.transact(fn repo ->
      with :ok <- Fence.check_in_tx(repo, run),
           {:ok, _} <- Run.record_pending_in_tx(repo, run),
           do:
             Ankole.Workflow.compensate_turn_error_in_tx(
               repo,
               run.event,
               error,
               DateTime.utc_now(:microsecond)
             )
    end)
    |> Ankole.Workflow.cleanup_terminal_transition()
  end

  defp apply_command(repo, _key, %{type: "command.stop"} = event, now),
    do:
      consume_command_feedback(repo, event, I18n.t("signals_gateway.reply.command_stopped"), now)

  defp apply_command(repo, key, %{type: "command.new"} = event, now) do
    with {:ok, _} <-
           AIGateway.end_active_conversation_in_tx(repo, key.agent_uid, key.session_id, now),
         do: consume_command_feedback(repo, event, "Started a new conversation.", now)
  end

  defp apply_command(repo, key, %{type: "command.retry"} = event, now) do
    case retry_target(event) do
      {:target, id} ->
        case append_retry_event(repo, key, event, id, now) do
          {:ok, retry, intents} ->
            with {:ok, _} <- consume_command_without_feedback(repo, event, now, intents),
                 do: {:ok, retry}

          {:ok, :target_unavailable} ->
            consume_retry_target_unavailable(repo, event, now)

          {:error, _} = error ->
            error
        end

      _ ->
        consume_retry_target_required(repo, event, now)
    end
  end

  defp apply_command(repo, _key, %{type: "command.steer"} = event, now),
    do: consume_command_feedback(repo, event, "Steer requires instructions.", now)

  defp apply_command(repo, _key, %{type: type} = event, now)
       when type in ["command.llm_help", "command.llm"] do
    with {:ok, profiles} <- ModelProfiles.list_custom_model_profiles(event.agent_uid),
         do: consume_command_feedback(repo, event, llm_help_text(profiles), now)
  end

  defp compress(key, event) do
    case AIGatewayLink.active_conversation(key.agent_uid, key.session_id) do
      nil ->
        process_command_feedback(event, "Nothing to compress.", DateTime.utc_now(:microsecond))

      conversation ->
        case Ankole.AIGateway.Compaction.compact_conversation(key.agent_uid, conversation.id, %{
               "metadata" => %{"actor_event_id" => event.id}
             }) do
          {:ok, %{compaction: compaction}} ->
            consume_compress_command(event, compaction, DateTime.utc_now(:microsecond))

          {:error, :no_compaction_candidate} ->
            process_command_feedback(
              event,
              "Nothing to compress.",
              DateTime.utc_now(:microsecond)
            )

          {:error, _} = error ->
            error
        end
    end
  end

  defp consume_compress_command(%ActorEvent{} = input, %{id: compaction_id} = compaction, now) do
    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- Actors.lock_actor_event_in_tx(repo, input.id),
           {:ok, outbox_intents} <-
             command_feedback_outbox_intents(repo, input, "Conversation compressed."),
           outbox_intents =
             Enum.map(outbox_intents, &Map.put(&1, :ai_message_id, compaction_id)),
           {:ok, completed_event} <-
             Actors.complete_command_event_in_tx(repo, input,
               completed_at: now,
               outbox_intents: outbox_intents
             ) do
        {:ok,
         %{
           status: :command_consumed,
           command: input.type,
           feedback: "Conversation compressed.",
           message: compaction,
           actor_event: completed_event
         }}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp consume_command_feedback(repo, %ActorEvent{} = input, text, now) do
    with {:ok, outbox_intents} <- command_feedback_outbox_intents(repo, input, text),
         {:ok, completed_event} <-
           Actors.complete_command_event_in_tx(repo, input,
             completed_at: now,
             outbox_intents: outbox_intents
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: text,
         actor_event: completed_event
       }}
    end
  end

  defp process_command_feedback(%ActorEvent{} = input, text, now) do
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, input.id) do
        %ActorEvent{} = input -> consume_command_feedback(repo, input, text, now)
        nil -> {:ok, %{status: :idle}}
      end
    end)
  end

  defp llm_help_text([]) do
    I18n.t("signals_gateway.reply.llm_help_empty", %{
      "usage" => I18n.t("signals_gateway.reply.llm_usage")
    })
  end

  defp llm_help_text(profiles) do
    profile_lines =
      profiles
      |> Enum.map_join("\n", fn profile ->
        "- #{profile["name"]}: #{profile["description"]}"
      end)

    I18n.t("signals_gateway.reply.llm_help", %{
      "usage" => I18n.t("signals_gateway.reply.llm_usage"),
      "profiles" => profile_lines
    })
  end

  defp consume_command_without_feedback(repo, %ActorEvent{} = input, now, outbox_intents) do
    Actors.complete_command_event_in_tx(repo, input,
      completed_at: now,
      outbox_intents: outbox_intents
    )
  end

  defp command_feedback_outbox_intents(_repo, %ActorEvent{signal_channel_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(_repo, %ActorEvent{source_entry_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(repo, %ActorEvent{} = input, text) do
    with {:ok, operation} <- SignalsGateway.outbox_operation_for_actor_event(input, repo) do
      command_name = String.replace_prefix(input.type, "command.", "")

      {:ok,
       [
         %{
           outbound_key: "command:#{input.id}:#{command_name}",
           operation: operation,
           target_source_entry_id: input.source_entry_id,
           provider_thread_id: input.provider_thread_id,
           payload: %{"text" => text},
           fallback_visible_text: text,
           idempotency_key: "command:#{input.id}:#{command_name}"
         }
       ]}
    end
  end

  defp append_retry_event(
         repo,
         actor_key,
         %ActorEvent{} = command_event,
         target_actor_event_id,
         now
       ) do
    with {:ok, %ActorEvent{} = source} <-
           retry_source_in_tx(repo, actor_key, command_event, target_actor_event_id),
         {:ok, outbox_intents} <- prepare_retry_response_graph(repo, source, now) do
      append_actor_event_retry(repo, command_event, source, outbox_intents, now)
    else
      {:ok, :target_unavailable} -> {:ok, :target_unavailable}
      {:noop, _reason} -> {:ok, :target_unavailable}
      {:error, :invalid_retry_target} -> {:ok, :target_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp retry_source_in_tx(repo, key, command_event, id) do
    with %ActorEvent{} = source <- lock_retry_source(repo, key, id),
         :ok <- validate_retry_source(repo, command_event, source),
         true <- AIGatewayLink.exact_turn_retryable_in_tx(repo, key, source.id) do
      {:ok, source}
    else
      _unavailable -> {:ok, :target_unavailable}
    end
  end

  defp append_actor_event_retry(repo, command_event, source, outbox_intents, now) do
    payload =
      source.payload
      |> TurnRetry.put_retry_metadata(source.id, "command.retry", %{})
      |> Map.put("id", "retry:#{command_event.id}")
      |> Map.put("time", DateTime.to_iso8601(now))

    with {:ok, retry_event} <-
           SignalsGateway.append_actor_event_in_tx(repo, %{
             source_work: source,
             agent_uid: source.agent_uid,
             binding_name: source.binding_name,
             session_id: source.session_id,
             source_event_id: "retry:#{command_event.id}",
             signal_channel_id: source.signal_channel_id,
             provider_thread_id: source.provider_thread_id,
             source_entry_id: source.source_entry_id,
             ambient_asked_source_entry_id: source.ambient_asked_source_entry_id,
             type: source.type,
             available_at: now,
             sender_key: command_event.sender_key,
             payload: payload
           }) do
      {:ok, retry_event, outbox_intents}
    end
  end

  defp prepare_retry_response_graph(
         repo,
         %ActorEvent{
           id: actor_event_id,
           agent_uid: agent_uid,
           session_id: session_id,
           completed_at: %DateTime{},
           final_response_id: final_response_id
         },
         now
       )
       when is_binary(final_response_id) do
    case AIGatewayLink.retract_visible_turn_suffix_in_tx(
           repo,
           agent_uid,
           session_id,
           actor_event_id,
           now,
           preserve_tool_history: true
         ) do
      {:ok, %{status: :retracted, retracted_message_ids: message_ids}} ->
        {:ok, ReplyDeletion.outbox_intents(repo, actor_event_id, message_ids)}

      {:ok, %{status: :preserved, preserved_message_ids: message_ids}} ->
        {:ok, ReplyDeletion.outbox_intents(repo, actor_event_id, message_ids)}

      {:ok, %{status: :noop, reason: reason}} ->
        {:noop, reason}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_retry_response_graph(repo, %ActorEvent{id: actor_event_id}, _now),
    do: {:ok, ReplyDeletion.outbox_intents(repo, actor_event_id, [])}

  defp lock_retry_source(repo, actor_key, target_actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^target_actor_event_id)
    |> where([event], event.agent_uid == ^actor_key.agent_uid)
    |> where([event], event.session_id == ^actor_key.session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp validate_retry_source(repo, command_event, source) do
    candidate_types = AIReplyPreview.channel_reply_event_types()

    cond do
      source.queue_sequence >= command_event.queue_sequence ->
        {:error, :invalid_retry_target}

      source.type not in candidate_types ->
        {:error, :invalid_retry_target}

      not terminal_retry_source?(source) ->
        {:error, :invalid_retry_target}

      source.type in ["command.new", "command.steer"] and command_args(source) == "" ->
        {:error, :invalid_retry_target}

      source.type == "command.steer" and match?(%DateTime{}, source.completed_at) and
          is_nil(source.final_response_id) ->
        {:error, :invalid_retry_target}

      intermediate_actor_event?(repo, source, command_event) ->
        {:error, :invalid_retry_target}

      not retry_source_retained?(repo, source) ->
        {:error, :invalid_retry_target}

      true ->
        :ok
    end
  end

  defp terminal_retry_source?(%ActorEvent{input_state: "open", completed_at: %DateTime{}}),
    do: true

  defp terminal_retry_source?(%ActorEvent{
         input_state: "dead_letter",
         dead_letter_at: %DateTime{}
       }),
       do: true

  defp terminal_retry_source?(%ActorEvent{}), do: false

  defp intermediate_actor_event?(repo, source, command_event) do
    ActorEvent
    |> where([event], event.agent_uid == ^source.agent_uid)
    |> where([event], event.session_id == ^source.session_id)
    |> where([event], event.queue_sequence > ^source.queue_sequence)
    |> where([event], event.queue_sequence < ^command_event.queue_sequence)
    |> where([event], event.type != "command.retry")
    |> repo.exists?()
  end

  defp retry_source_retained?(_repo, %ActorEvent{signal_channel_id: nil}), do: true

  defp retry_source_retained?(repo, %ActorEvent{} = event) do
    source_entry_ids = ActorEvent.source_entry_ids(event)

    if source_entry_ids == [] do
      true
    else
      retained_source_entry_ids =
        Entry
        |> where([entry], entry.signal_channel_id == ^event.signal_channel_id)
        |> where([entry], entry.source_entry_id in ^source_entry_ids)
        |> select([entry], entry.source_entry_id)
        |> repo.all()
        |> MapSet.new()

      Enum.all?(source_entry_ids, &MapSet.member?(retained_source_entry_ids, &1))
    end
  end

  defp consume_retry_target_required(repo, input, now) do
    consume_command_feedback(
      repo,
      input,
      I18n.t("signals_gateway.reply.retry_target_required"),
      now
    )
  end

  defp consume_retry_target_unavailable(repo, input, now) do
    consume_command_feedback(
      repo,
      input,
      I18n.t("signals_gateway.reply.retry_target_unavailable"),
      now
    )
  end

  defp command_args(%ActorEvent{payload: payload}) when is_map(payload) do
    payload
    |> get_in(["data", "command", "argsText"])
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp command_args(_input), do: ""

  defp retry_target(%ActorEvent{payload: %{"data" => %{"command" => command}}})
       when is_map(command) do
    case Map.fetch(command, "targetActorEventId") do
      :error ->
        :bare

      {:ok, actor_event_id} when is_binary(actor_event_id) and actor_event_id != "" ->
        {:target, actor_event_id}

      {:ok, _unresolved} ->
        :unresolved
    end
  end

  defp retry_target(%ActorEvent{}), do: :bare
end
