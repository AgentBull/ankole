defmodule Ankole.Sessions.Commands do
  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.AIGateway.CompactionRequests

  @moduledoc """
  Applies conversation commands through their existing domain owners.

  Commands consume durable input. Writes that interrupt an active Run use
  its epoch. A retry retains tool records when the visible suffix contains
  tool calls or results.
  """
  import Ash.Expr, only: [expr: 1]
  alias Ankole.I18n
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Run
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Delivery.Preview

  alias Ankole.Sessions.MessageLifecycle
  alias Ankole.Conversations.Delivery.Deletion
  alias Ankole.Sessions.SessionReset

  @spec route(Signal.t()) :: :run | :control
  def route(%Signal{producer: :external}), do: :run

  def route(%Signal{producer: :kernel, type: "command.steer", last_attempt_at: %DateTime{}}),
    do: :run

  def route(%Signal{producer: :kernel, type: type} = event) do
    cond do
      type in [
        "session.reset_due",
        "conversation.message.removed",
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

  def route(_event), do: :run

  @spec injectable?(Signal.t()) :: boolean()
  def injectable?(%Signal{producer: :external}), do: false

  def injectable?(
        %Signal{producer: :kernel, type: "command.retry", last_attempt_at: %DateTime{}} = event
      ),
      do: retry_target(event) == :bare

  def injectable?(event),
    do:
      not queued_followup?(event) and route(event) == :run and
        event.type in [
          "command.steer",
          "conversation.message.addressed",
          "input.revised"
        ]

  @doc "A native follow-up that must start its own turn, rather than join the active one."
  def queued_followup?(%Signal{
        producer: :kernel,
        type: "conversation.message.addressed",
        data: %{"delivery_mode" => "queue"}
      }),
      do: true

  def queued_followup?(_event), do: false

  @spec profile(Signal.t()) :: String.t() | nil
  def profile(%Signal{producer: :kernel, data: data}) when is_map(data),
    do: get_in(data, ["command", "modelProfile"])

  def profile(_event), do: nil

  @spec prepare_new_in_tx(Signal.t(), DateTime.t()) :: :ok | {:error, term()}
  def prepare_new_in_tx(
        %Signal{producer: :kernel, type: "command.new", last_attempt_at: nil} = event,
        now
      ) do
    with {:ok, _} <-
           ModelHistory.end_active_conversation_in_tx(
             event.agent_uid,
             event.session_id,
             now
           ),
         do: :ok
  end

  def prepare_new_in_tx(_event, _now), do: :ok

  @spec process(map(), Signal.t()) :: {:ok, map()} | {:error, term()}
  def process(_key, %Signal{producer: :external}), do: {:error, :not_a_kernel_control}

  def process(key, event) do
    case Ankole.Sessions.Admission.authorize_event(event) do
      {:ok, %{status: live_status} = event} when live_status in [:queued, :running] ->
        process_authorized(key, event)

      {:ok, event} ->
        {:ok, %{status: :dead_letter, signal: event}}

      error ->
        error
    end
  end

  defp process_authorized(key, %{type: "session.reset_due"} = event),
    do: SessionReset.process_due(key, event, [])

  defp process_authorized(_key, %{type: "conversation.message.removed"} = event),
    do: MessageLifecycle.process(event, [])

  defp process_authorized(key, %{type: "command.compress"} = event), do: compress(key, event)

  defp process_authorized(key, event) do
    now = DateTime.utc_now(:microsecond)

    Ankole.Repo.transact_top_level(fn -> apply_command_in_tx(key, event, now) end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def apply_command_in_tx(key, event, now) do
    with :ok <- Queue.lock_session_in_tx(key.agent_uid, key.session_id),
         %Signal{status: live_status} = current
         when live_status in [:queued, :running] <-
           PreviewStates.load(Ankole.Signals.lock_signal_in_tx(event.id)) do
      apply_command(key, current, now)
    else
      _ -> {:ok, :already_consumed}
    end
  end

  @spec interrupt(Run.t(), Signal.t()) :: {:ok, map()} | {:error, term()}
  def interrupt(_run, %Signal{producer: :external}), do: {:error, :not_a_kernel_control}

  def interrupt(run, %{type: "input.revised"} = event),
    do: Ankole.Sessions.Revisions.apply(run, event)

  def interrupt(run, %{type: "command.retry"} = event) do
    if retry_target(event) == :bare,
      do: retry_current(run, event),
      else: stop_and_process(run, event)
  end

  def interrupt(run, event), do: stop_and_process(run, event)

  @spec retry_action(Run.t(), Signal.t()) :: {:ok, :interrupt | :continue} | {:error, term()}
  def retry_action(_run, %Signal{producer: :external}), do: {:ok, :continue}

  def retry_action(run, event) do
    if retry_target(event) == :bare do
      {:ok, if(event.last_attempt_at, do: :continue, else: :interrupt)}
    else
      Ankole.Repo.transact_top_level(fn -> retry_action_in_tx(run, event) end)
      |> Ankole.Errors.reason()
    end
  end

  @doc false
  def retry_action_in_tx(run, event) do
    with :ok <- Queue.lock_session_in_tx(run.agent_uid, run.session_id),
         :ok <- Fence.check_in_tx(run),
         %Signal{status: live_status} = current
         when live_status in [:queued, :running] <-
           PreviewStates.load(Ankole.Signals.lock_signal_in_tx(event.id)) do
      retry_target_action_in_tx(run, current)
    else
      nil -> {:ok, :continue}
      %Signal{} -> {:ok, :continue}
      error -> error
    end
  end

  defp retry_target_action_in_tx(run, current) do
    case retry_target(current) do
      {:target, id} ->
        case retry_source_in_tx(run, current, id) do
          {:ok, %Signal{}} ->
            {:ok, :interrupt}

          {:ok, :target_unavailable} ->
            with {:ok, _} <-
                   consume_retry_target_unavailable(
                     current,
                     DateTime.utc_now(:microsecond)
                   ),
                 do: {:ok, :continue}
        end

      _unresolved ->
        with {:ok, _} <-
               consume_retry_target_required(current, DateTime.utc_now(:microsecond)),
             do: {:ok, :continue}
    end
  end

  defp retry_current(run, event) do
    now = DateTime.utc_now(:microsecond)

    Ankole.Repo.transact_top_level(fn -> retry_current_in_tx(run, event, now) end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def retry_current_in_tx(run, event, now) do
    with :ok <- Run.lock_for_write_in_tx(run),
         :ok <- Fence.check_in_tx(run),
         {:ok, _} <-
           ModelHistory.retract_generating_turn_in_tx(
             run,
             run.signal_id,
             now,
             "command.retry"
           ),
         # The model can commit a call before its terminal message arrives.
         {:ok, {_state, run}} <- Run.restore_in_tx(run),
         {:ok, {run, _}} <- Run.record_pending_in_tx(run),
         {:ok, history} <-
           ModelHistory.retract_visible_turn_suffix_in_tx(
             run.agent_uid,
             run.session_id,
             run.signal_id,
             now,
             preserve_tool_history: true
           ) do
      commit_current_retry_in_tx(run, event, history.status, now)
    end
  end

  defp commit_current_retry_in_tx(run, event, :preserved, now) do
    with {:ok, _} <-
           Ankole.Signals.transition_in_tx(event, :start_attempt, %{last_attempt_at: now}),
         do: {:ok, Run.reset(run)}
  end

  defp commit_current_retry_in_tx(run, event, _history_status, now) do
    ids = [run.signal_id | run.steer_event_ids]

    with {:ok, _} <- Queue.complete_command_event_in_tx(event, completed_at: now),
         {:ok, _reset} <- Ankole.Signals.reset_attempts_in_tx(ids, now),
         do: {:ok, :retry}
  end

  defp stop_and_process(run, event) do
    with {:ok, %{reply_event: reply_event}} <- Run.finalize(run, :stopped) do
      settle_stopped_preview(reply_event, event)
      if route(event) == :run, do: {:ok, :restart}, else: process(run, event)
    end
  end

  # A provider-visible preview card shows the stop instead of its working
  # state. The edit is presentation only; a failure leaves the stop done.
  defp settle_stopped_preview(reply_event, command) do
    with %Signal{preview: %PreviewState{provider_message_id: id}} =
           event
         when is_binary(id) <-
           PreviewStates.load_signal(reply_event.id),
         {:error, reason} <-
           Ankole.Repo.transact_top_level(fn ->
             post_stopped_notice_in_tx(event, command.type)
           end)
           |> Ankole.Errors.reason() do
      Ankole.Logging.warning(
        "sessions.commands.stopped_preview_not_committed",
        "stopped preview card not committed",
        %{signal_id: event.id, reason: inspect(reason, limit: 20)}
      )
    end
  end

  @doc false
  def post_stopped_notice_in_tx(event, command_type) do
    Ankole.Sessions.Notices.post_in_tx(
      event,
      :stopped,
      I18n.t("conversations.delivery.reply.command_stopped"),
      %{"reason" => command_type}
    )
  end

  def workflow_failure(run, failure) do
    Ankole.Repo.transact_top_level(fn -> workflow_failure_in_tx(run, failure) end)
    |> Ankole.Errors.reason()
    |> Ankole.Workflow.cleanup_terminal_transition()
  end

  @doc false
  def workflow_failure_in_tx(run, failure) do
    with :ok <- Run.lock_for_write_in_tx(run),
         :ok <- Fence.check_in_tx(run),
         do:
           Ankole.Workflow.TaskLifecycle.submit_result_in_tx(
             run.spec.request_context["call_id"],
             run.agent_uid,
             run.session_id,
             failure
           )
  end

  def workflow_error(run, error) do
    Ankole.Repo.transact_top_level(fn -> workflow_error_in_tx(run, error) end)
    |> Ankole.Errors.reason()
    |> Ankole.Workflow.cleanup_terminal_transition()
  end

  @doc false
  def workflow_error_in_tx(run, error) do
    with :ok <- Run.lock_for_write_in_tx(run),
         :ok <- Fence.check_in_tx(run),
         {:ok, _} <- Run.record_pending_in_tx(run),
         do:
           Ankole.Workflow.TaskLifecycle.compensate_turn_error_in_tx(
             run.event,
             error,
             DateTime.utc_now(:microsecond)
           )
  end

  defp apply_command(_key, %{type: "command.stop"} = event, now),
    do:
      consume_command_feedback(
        event,
        I18n.t("conversations.delivery.reply.command_stopped"),
        now
      )

  defp apply_command(key, %{type: "command.new"} = event, now) do
    with {:ok, _} <-
           ModelHistory.end_active_conversation_in_tx(key.agent_uid, key.session_id, now),
         do: consume_command_feedback(event, "Started a new conversation.", now)
  end

  defp apply_command(key, %{type: "command.retry"} = event, now),
    do: retry_in_tx(key, event, now)

  defp apply_command(_key, %{type: "command.steer"} = event, now),
    do: consume_command_feedback(event, "Steer requires instructions.", now)

  defp apply_command(_key, %{type: type} = event, now)
       when type in ["command.llm_help", "command.llm"] do
    with {:ok, profiles} <- ModelProfiles.list_custom_model_profiles(event.agent_uid),
         do: consume_command_feedback(event, llm_help_text(profiles), now)
  end

  @doc "Applies an explicit retry under the caller's existing session lock and transaction."
  def retry_in_tx(key, %{type: "command.retry"} = event, now) do
    case retry_target(event) do
      {:target, id} ->
        case append_retry_event(key, event, id, now) do
          {:ok, retry, intents} ->
            with {:ok, _} <- consume_command_without_feedback(event, now, intents),
                 do: {:ok, retry}

          {:ok, :target_unavailable} ->
            consume_retry_target_unavailable(event, now)

          {:error, _} = error ->
            error
        end

      _ ->
        consume_retry_target_required(event, now)
    end
  end

  defp compress(key, event) do
    case ModelHistory.active_conversation(key.agent_uid, key.session_id) do
      nil ->
        process_command_feedback(event, "Nothing to compress.", DateTime.utc_now(:microsecond))

      conversation ->
        case CompactionRequests.compact_conversation(key.agent_uid, conversation.id, %{
               "metadata" => %{"signal_id" => event.id}
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

  defp consume_compress_command(%Signal{} = input, compaction, now) do
    Ankole.Repo.transact_top_level(fn ->
      consume_compress_command_in_tx(input, compaction, now)
    end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def consume_compress_command_in_tx(
        %Signal{} = input,
        %{id: compaction_id} = compaction,
        now
      ) do
    with %Signal{} = input <-
           PreviewStates.load(Ankole.Signals.lock_signal_in_tx(input.id)),
         {:ok, intents} <- command_feedback_intents(input, "Conversation compressed."),
         intents = Enum.map(intents, &Map.put(&1, :ai_message_id, compaction_id)),
         {:ok, _} <- commit_feedback_in_tx(input, intents),
         {:ok, completed_event} <-
           Queue.complete_command_event_in_tx(input, completed_at: now) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: "Conversation compressed.",
         message: compaction,
         signal: completed_event
       }}
    else
      nil -> {:ok, %{status: :idle}}
      {:error, _reason} = error -> error
    end
  end

  defp consume_command_feedback(%Signal{} = input, text, now) do
    with {:ok, intents} <- command_feedback_intents(input, text),
         {:ok, _} <- commit_feedback_in_tx(input, intents),
         {:ok, completed_event} <-
           Queue.complete_command_event_in_tx(input, completed_at: now) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: text,
         signal: completed_event
       }}
    end
  end

  defp process_command_feedback(%Signal{} = input, text, now) do
    Ankole.Repo.transact_top_level(fn ->
      command_feedback_in_tx(input, text, now)
    end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def command_feedback_in_tx(%Signal{} = input, text, now) do
    case PreviewStates.load(Ankole.Signals.lock_signal_in_tx(input.id)) do
      %Signal{} = input -> consume_command_feedback(input, text, now)
      nil -> {:ok, %{status: :idle}}
    end
  end

  defp llm_help_text([]) do
    I18n.t("conversations.delivery.reply.llm_help_empty", %{
      "usage" => I18n.t("conversations.delivery.reply.llm_usage")
    })
  end

  defp llm_help_text(profiles) do
    profile_lines =
      profiles
      |> Enum.map_join("\n", fn profile ->
        "- #{profile["name"]}: #{profile["description"]}"
      end)

    I18n.t("conversations.delivery.reply.llm_help", %{
      "usage" => I18n.t("conversations.delivery.reply.llm_usage"),
      "profiles" => profile_lines
    })
  end

  defp consume_command_without_feedback(%Signal{} = input, now, intents) do
    with {:ok, _} <- commit_feedback_in_tx(input, intents),
         do: Queue.complete_command_event_in_tx(input, completed_at: now)
  end

  defp commit_feedback_in_tx(signal, intents) do
    intents
    |> Enum.map(fn attrs ->
      attrs
      |> Map.put_new(:agent_uid, signal.agent_uid)
      |> Map.put_new(:binding_name, signal.reply_binding_name)
      |> Map.put_new(:conversation_id, signal.conversation_id)
      |> Map.put_new(:provider_thread_id, signal.provider_thread_id)
      |> Map.put_new(:reply_to_provider_message_id, signal.provider_message_id)
      |> Map.put_new(:source_signal_id, signal.id)
      |> then(&Ankole.Conversations.Delivery.commit_in_tx(&1))
    end)
    |> Ankole.Attrs.collect_results()
  end

  defp command_feedback_intents(%Signal{conversation_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_intents(%Signal{provider_message_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_intents(%Signal{} = input, text) do
    with {:ok, operation} <-
           Ankole.Conversations.Delivery.operation_for_signal(input) do
      command_name = String.replace_prefix(input.type, "command.", "")

      {:ok,
       [
         %{
           outbound_key: "command:#{input.id}:#{command_name}",
           operation: operation,
           target_provider_message_id: input.provider_message_id,
           provider_thread_id: input.provider_thread_id,
           payload: %{"text" => text},
           fallback_visible_text: text,
           idempotency_key: "command:#{input.id}:#{command_name}"
         }
       ]}
    end
  end

  defp append_retry_event(
         session_key,
         %Signal{} = command_event,
         target_signal_id,
         now
       ) do
    with {:ok, %Signal{} = source} <-
           retry_source_in_tx(session_key, command_event, target_signal_id),
         {:ok, intents} <- prepare_retry_response_graph(source, now) do
      append_signal_retry(command_event, source, intents, now)
    else
      {:ok, :target_unavailable} -> {:ok, :target_unavailable}
      {:noop, _reason} -> {:ok, :target_unavailable}
      {:error, :invalid_retry_target} -> {:ok, :target_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def retry_source_in_tx(key, command_event, id) do
    with %Signal{} = source <- lock_retry_source(key, id),
         :ok <- validate_retry_source(command_event, source),
         true <- ModelHistory.exact_turn_retryable_in_tx(key, source.id) do
      {:ok, source}
    else
      _unavailable -> {:ok, :target_unavailable}
    end
  end

  defp append_signal_retry(command_event, source, intents, now) do
    source = native_edit_source(command_event, source)

    payload =
      Signal.envelope(source)
      |> retry_payload(source)
      |> Map.put("id", "retry:#{command_event.id}")
      |> Map.put("time", DateTime.to_iso8601(now))

    with {:ok, retry_event} <-
           Ankole.Signals.accept_in_tx(%{
             producer: source.producer,
             source: payload["source"],
             id: "retry:#{command_event.id}",
             type: source.type,
             subject: source.subject,
             time: payload["time"],
             available_at: now,
             target: %{agent_uid: source.agent_uid, session_id: source.session_id},
             sender: command_event.sender_key,
             authorization: Ankole.Principals.WorkAccess.fields(source),
             reply_route: %{
               binding_name: source.reply_binding_name,
               conversation_id: source.conversation_id,
               provider_thread_id: source.provider_thread_id,
               provider_message_id: source.provider_message_id
             },
             data: payload["data"],
             extensions: source.extensions,
             message_id: source.message_id,
             ambient_asked_message_id: source.ambient_asked_message_id
           }) do
      {:ok, retry_event, intents}
    end
  end

  # The original Signal is the consumed text version. A native edit changes
  # only the new retry payload; it must not change a running Job's old input.
  defp native_edit_source(
         %Signal{
           producer: :kernel,
           source: "native-control:" <> conversation_id,
           data: %{"native_action" => "edit_last", "native_edit_text" => text}
         },
         %Signal{producer: :kernel, conversation_id: conversation_id} = source
       )
       when is_binary(text) or is_nil(text) do
    text = if is_binary(text) and String.trim(text) == "", do: nil, else: text
    data = Map.put(source.data, "text", text)
    data = if is_map(data["entry"]), do: put_in(data, ["entry", "text"], text), else: data
    %{source | data: data}
  end

  defp native_edit_source(_command, source), do: source

  defp retry_payload(payload, %Signal{producer: :kernel, id: id} = source) do
    payload =
      if source.type == "conversation.message.addressed" and is_binary(source.data["text"]) do
        update_in(payload, ["data", "entry"], fn entry ->
          Map.put_new(entry || %{}, "text", source.data["text"])
        end)
      else
        payload
      end

    payload
    |> Signal.put_retry_metadata(id, "command.retry", %{})
    |> Map.update!("data", &Map.delete(&1, "delivery_mode"))
  end

  defp retry_payload(payload, _external_source), do: payload

  defp prepare_retry_response_graph(
         %Signal{
           id: signal_id,
           agent_uid: agent_uid,
           session_id: session_id,
           status: :completed,
           final_response_id: final_response_id
         },
         now
       )
       when is_binary(final_response_id) do
    case ModelHistory.retract_visible_turn_suffix_in_tx(
           agent_uid,
           session_id,
           signal_id,
           now,
           preserve_tool_history: true
         ) do
      {:ok, %{status: :retracted, retracted_message_ids: message_ids}} ->
        {:ok, Deletion.intents(signal_id, message_ids)}

      {:ok, %{status: :preserved, preserved_message_ids: message_ids}} ->
        {:ok, Deletion.intents(signal_id, message_ids)}

      {:ok, %{status: :noop, reason: reason}} ->
        {:noop, reason}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_retry_response_graph(%Signal{id: signal_id}, _now),
    do: {:ok, Deletion.intents(signal_id, [])}

  defp lock_retry_source(session_key, target_signal_id),
    do: Ankole.Signals.lock_session_signal_in_tx(session_key, target_signal_id)

  defp validate_retry_source(command_event, source) do
    candidate_types = Preview.channel_reply_event_types()
    before_sequence = command_event && command_event.queue_sequence

    cond do
      before_sequence && source.queue_sequence >= before_sequence ->
        {:error, :invalid_retry_target}

      Signal.produced_by_kernel?(source) and source.type not in candidate_types ->
        {:error, :invalid_retry_target}

      not terminal_retry_source?(source) ->
        {:error, :invalid_retry_target}

      Signal.produced_by_kernel?(source) and
        source.type in ["command.new", "command.steer"] and command_args(source) == "" ->
        {:error, :invalid_retry_target}

      Signal.produced_by_kernel?(source) and source.type == "command.steer" and
        match?(%DateTime{}, source.completed_at) and
          is_nil(source.final_response_id) ->
        {:error, :invalid_retry_target}

      intermediate_signal?(source, before_sequence) ->
        {:error, :invalid_retry_target}

      not retry_source_retained?(source) ->
        {:error, :invalid_retry_target}

      true ->
        :ok
    end
  end

  defp terminal_retry_source?(%Signal{status: :completed}),
    do: true

  defp terminal_retry_source?(%Signal{
         status: :dead_letter,
         dead_letter_at: %DateTime{}
       }),
       do: true

  defp terminal_retry_source?(%Signal{}), do: false

  defp intermediate_signal?(source, before_sequence) do
    filter =
      expr(
        agent_uid == ^source.agent_uid and session_id == ^source.session_id and
          queue_sequence > ^source.queue_sequence and
          (producer != :kernel or type != "command.retry")
      )

    filter =
      if before_sequence,
        do: expr(^filter and queue_sequence < ^before_sequence),
        else: filter

    Ankole.Signals.list_signals!(query: [filter: filter, select: [:id], limit: 1]) != []
  end

  defp retry_source_retained?(%Signal{conversation_id: nil}), do: true

  defp retry_source_retained?(%Signal{} = event) do
    provider_message_ids = Signal.provider_message_ids(event)

    if provider_message_ids == [] do
      true
    else
      retained_provider_message_ids =
        [
          query: [
            filter: [
              conversation_id: event.conversation_id,
              provider_message_id: [in: provider_message_ids]
            ],
            select: [:provider_message_id]
          ]
        ]
        |> Ankole.Conversations.list_external_message_refs!()
        |> MapSet.new(& &1.provider_message_id)

      Enum.all?(provider_message_ids, &MapSet.member?(retained_provider_message_ids, &1))
    end
  end

  defp consume_retry_target_required(input, now) do
    consume_command_feedback(
      input,
      I18n.t("conversations.delivery.reply.retry_target_required"),
      now
    )
  end

  defp consume_retry_target_unavailable(input, now) do
    consume_command_feedback(
      input,
      I18n.t("conversations.delivery.reply.retry_target_unavailable"),
      now
    )
  end

  defp command_args(%Signal{producer: :kernel, data: data}) when is_map(data) do
    data
    |> get_in(["command", "argsText"])
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp command_args(_input), do: ""

  defp retry_target(%Signal{data: %{"command" => command}})
       when is_map(command) do
    case Map.fetch(command, "targetSignalId") do
      :error ->
        :bare

      {:ok, signal_id} when is_binary(signal_id) and signal_id != "" ->
        {:target, signal_id}

      {:ok, _unresolved} ->
        :unresolved
    end
  end

  defp retry_target(%Signal{}), do: :bare
end
