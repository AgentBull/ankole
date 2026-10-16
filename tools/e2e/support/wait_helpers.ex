defmodule Ankole.E2E.WaitHelpers do
  @moduledoc """
  Deadline-based polling helpers for real Docker worker e2e scenarios.

  All ingress and worker effects are asynchronous (WS dispatch tasks, worker
  turns, AIGateway commits), so durable facts are awaited by polling PostgreSQL
  until a deadline instead of asserting immediately after a send.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.External
  alias Ankole.Conversations.ExternalMessageRef

  @doc """
  Inserts old transcript rows plus a large recent tail for deterministic compression.

  `/compress` keeps the recent tail and summarizes older messages. Compression
  tests need enough transcript mass to force the compression path without
  changing production thresholds.
  """
  @spec seed_compression_history!(String.t(), Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def seed_compression_history!(agent_uid, conversation_id) do
    old_user =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        "Compression seed: the release codename is ANKOLE_REAL_E2E.",
        nil
      )

    old_assistant =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "assistant",
        "Compression seed recorded: ANKOLE_REAL_E2E.",
        old_user.id
      )

    old_followup_user =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        "Compression seed follow-up: keep ANKOLE_REAL_E2E available after manual compression.",
        old_assistant.id
      )

    old_followup_assistant =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "assistant",
        "Compression seed follow-up recorded for ANKOLE_REAL_E2E.",
        old_followup_user.id
      )

    recent_tail =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        String.duplicate("Recent tail retained after compression. ", 2_500),
        old_followup_assistant.id
      )

    _recent_tail =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "assistant",
        String.duplicate("Recent tail retained after compression. ", 2_500),
        recent_tail.id
      )

    [old_user.id, old_assistant.id, old_followup_user.id, old_followup_assistant.id]
  end

  @doc """
  Builds a monotonic deadline for polling a real Docker worker e2e condition.
  """
  @spec deadline(pos_integer()) :: integer()
  def deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @doc """
  Polls `fun` every 50ms until it returns `{:ok, value}` or the deadline passes.

  For waits that are not tied to a worker container process. `fun` returning
  `nil` or `false` keeps polling; any other value completes the wait.
  """
  @spec wait_until(integer(), (-> term())) :: {:ok, term()} | :timeout
  def wait_until(deadline, fun) when is_function(fun, 0) do
    case poll_value(fun) do
      result when result in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(50)
          wait_until(deadline, fun)
        end

      {:ok, value} ->
        {:ok, value}

      value ->
        {:ok, value}
    end
  end

  @doc """
  Waits until the Agent's Worker is ready and has a free Turn slot.
  """
  @spec wait_for_worker(map(), integer()) :: {:ok, AgentWorker.t()}
  def wait_for_worker(%{agent_uid: agent_uid} = process, deadline) do
    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{state: "ready"} = worker ->
        case AgentWorker.available_slots(worker) > 0 do
          true ->
            {:ok, worker}

          false ->
            receive_or_wait(process, deadline, fn -> wait_for_worker(process, deadline) end)
        end

      _worker ->
        receive_or_wait(process, deadline, fn -> wait_for_worker(process, deadline) end)
    end
  end

  @doc """
  Waits for the AI message associated with one Signal to reach a status.

  Accepts the runtime-facing status names (`"succeeded"`, `"failed"`,
  `"cancelled"`) and maps them onto the `ai_gateway_messages` status column.
  """
  @spec wait_for_turn_status(map(), Ecto.UUID.t(), String.t(), integer()) ::
          {:ok, Message.t()}
  def wait_for_turn_status(process, signal_id, status, deadline) do
    expected_status = ai_message_status(status)

    case ai_message_for_signal(signal_id) do
      %Message{status: ^expected_status} = message ->
        {:ok, message}

      _other ->
        receive_or_wait(process, deadline, fn ->
          wait_for_turn_status(process, signal_id, status, deadline)
        end)
    end
  end

  @doc """
  Waits until the Signal is complete and returns its latest AI message.

  A tool loop can commit an earlier function_call row with status `complete`
  while the Signal remains live. The adopted final answer is the latest
  complete message after `signals.completed_at` is written.
  """
  @spec wait_for_completed_signal_message(map(), Ecto.UUID.t(), integer()) ::
          {:ok, Message.t()}
  def wait_for_completed_signal_message(process, signal_id, deadline) do
    with_transient_db_retry(process, deadline, fn ->
      case {Repo.get(Signal, signal_id), final_ai_message_for_signal(signal_id)} do
        {%Signal{completed_at: %DateTime{}}, %Message{status: "complete"} = message} ->
          {:ok, message}

        {%Signal{completed_at: %DateTime{}}, nil} ->
          case ai_message_for_signal(signal_id) do
            %Message{status: "error"} = message ->
              flunk(
                "Signal completed with failed AI message: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(signal_id))} #{inspect_process(process)}"
              )

            _message ->
              receive_or_wait(process, deadline, fn ->
                wait_for_completed_signal_message(process, signal_id, deadline)
              end)
          end

        {%Signal{completed_at: %DateTime{}}, %Message{status: "error"} = message} ->
          flunk(
            "Signal completed with failed AI message: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(signal_id))} #{inspect_process(process)}"
          )

        _other ->
          receive_or_wait(process, deadline, fn ->
            wait_for_completed_signal_message(process, signal_id, deadline)
          end)
      end
    end)
  end

  @doc """
  Waits until `signals.completed_at` is written, without requiring any AI
  message (e.g. ambient silence commits a noop completion).
  """
  @spec wait_for_signal_completed(map(), Ecto.UUID.t(), integer()) ::
          {:ok, Signal.t()}
  def wait_for_signal_completed(process, signal_id, deadline) do
    case Repo.get(Signal, signal_id) do
      %Signal{completed_at: %DateTime{}} = event ->
        {:ok, event}

      _other ->
        receive_or_wait(process, deadline, fn ->
          wait_for_signal_completed(process, signal_id, deadline)
        end)
    end
  end

  @doc """
  Waits until a Signal reaches its durable dead-letter state.
  """
  @spec wait_for_signal_dead_letter(map(), Ecto.UUID.t(), integer()) ::
          {:ok, Signal.t()}
  def wait_for_signal_dead_letter(process, signal_id, deadline) do
    case Repo.get(Signal, signal_id) do
      %Signal{input_state: "dead_letter", dead_letter_at: %DateTime{}} = event ->
        {:ok, event}

      _other ->
        receive_or_wait(process, deadline, fn ->
          wait_for_signal_dead_letter(process, signal_id, deadline)
        end)
    end
  end

  @doc """
  Waits for the final Conversation mirror row associated with an AI message.
  """
  @spec wait_for_final_mirror(map(), Ecto.UUID.t(), integer()) ::
          {:ok, %{message: ConversationMessage.t(), external_ref: ExternalMessageRef.t()}}
  def wait_for_final_mirror(process, ai_message_id, deadline) do
    case Ankole.SessionsCase.final_message_observation(ai_message_id) do
      %{message: %ConversationMessage{}} = observation ->
        {:ok, observation}

      nil ->
        receive_or_wait(process, deadline, fn ->
          wait_for_final_mirror(process, ai_message_id, deadline)
        end)
    end
  end

  @doc """
  Waits for the latest final Conversation mirror of one completed Signal.

  Ordinary streamed AI replies commit one final intent row. Cron replies can
  commit one target-scoped row for each delivery target. This helper selects
  the primary row. A steer keeps that message on the original Turn stream but
  makes the accepted steer event own the intent. The intent maps those two
  Signal identities.
  The wait loop runs due conversation and Delivery jobs because Oban is manual
  in these tests.
  """
  @spec wait_for_completed_final_reply(map(), Ecto.UUID.t(), integer()) ::
          {:ok, %{message: ConversationMessage.t(), external_ref: ExternalMessageRef.t()},
           Message.t()}
  def wait_for_completed_final_reply(process, signal_id, deadline) do
    Process.put(
      :ankole_e2e_timeout_debug,
      fn ->
        "durable_state=#{inspect(durable_commit_state(signal_id))} messages=#{inspect(ai_messages_for_signal(signal_id))}"
      end
    )

    if System.monotonic_time(:millisecond) > deadline do
      flunk(
        "timed out waiting for final reply: durable_state=#{inspect(durable_commit_state(signal_id))} messages=#{inspect(ai_messages_for_signal(signal_id))} #{inspect_process(process)}"
      )
    end

    with_transient_db_retry(process, deadline, fn ->
      case {Repo.get(Signal, signal_id), mirrored_latest_final_reply_for_signal(signal_id)} do
        {%Signal{completed_at: %DateTime{}},
         {%{message: %ConversationMessage{}} = reply, %Message{} = message}} ->
          {:ok, reply, message}

        {%Signal{completed_at: %DateTime{}}, nil} ->
          receive_or_wait(process, deadline, fn ->
            wait_for_completed_final_reply(process, signal_id, deadline)
          end)

        _other ->
          receive_or_wait(process, deadline, fn ->
            wait_for_completed_final_reply(process, signal_id, deadline)
          end)
      end
    end)
  end

  @doc """
  Waits for the explicit side-effect intent row committed for one Signal
  and AI message. Plain final-reply rows use the `ai-reply:<message_id>` key and
  are handled by `wait_for_completed_final_reply/3`.
  """
  @spec wait_for_intent_for_input(map(), Ecto.UUID.t(), integer(), Ecto.UUID.t()) ::
          {:ok, Intent.t()}
  def wait_for_intent_for_input(process, source_signal_id, deadline, ai_message_id) do
    case side_effect_intents_for_input(source_signal_id, ai_message_id) do
      [%Intent{} = intent] ->
        {:ok, intent}

      [] ->
        flunk_if_terminal_without_intent(
          process,
          source_signal_id,
          "intent for source_signal_id=#{source_signal_id}",
          fn ->
            side_effect_intents_for_input(source_signal_id, ai_message_id)
          end
        )

        receive_or_wait(process, deadline, fn ->
          wait_for_intent_for_input(process, source_signal_id, deadline, ai_message_id)
        end)

      intents ->
        flunk(
          "expected one side-effect intent for source_signal_id=#{source_signal_id} ai_message_id=#{ai_message_id}, found #{length(intents)}: #{inspect(Enum.map(intents, & &1.outbound_key))}"
        )
    end
  end

  defp side_effect_intents_for_input(source_signal_id, ai_message_id) do
    final_reply_key = "ai-reply:#{ai_message_id}"

    Intent
    |> where([intent], intent.source_signal_id == ^source_signal_id)
    |> where([intent], intent.ai_message_id == ^ai_message_id)
    |> where([intent], intent.outbound_key != ^final_reply_key)
    |> order_by([intent], asc: intent.inserted_at, asc: intent.outbound_key)
    |> Repo.all()
  end

  @doc """
  Waits for the final intent of one Signal without knowing the message id.

  Convenience wrapper: first waits for the Signal to complete with an AI
  message, then waits for the intent row committed for that message.
  """
  @spec wait_for_completed_intent(map(), Ecto.UUID.t(), integer()) ::
          {:ok, Intent.t(), Message.t()}
  def wait_for_completed_intent(process, signal_id, deadline) do
    with {:ok, message} <-
           wait_for_completed_signal_message(process, signal_id, deadline),
         {:ok, intent} <-
           wait_for_intent_for_input(process, signal_id, deadline, message.id) do
      {:ok, intent, message}
    end
  end

  @doc """
  Returns every AI message committed for one Signal in commit order.
  """
  @spec ai_messages_for_signal(Ecto.UUID.t()) :: [Message.t()]
  def ai_messages_for_signal(signal_id) do
    Message
    |> where(
      [message],
      fragment("?#>>'{request_metadata,signal_id}'", message.metadata) == ^signal_id
    )
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> Repo.all()
  end

  defp insert_transcript_message!(agent_uid, conversation_id, role, text, previous_message_id) do
    %Message{}
    |> Message.changeset(%{
      subject_uid: agent_uid,
      conversation_id: conversation_id,
      previous_message_id: previous_message_id,
      role: role,
      type: "message",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      metadata: %{"e2e_seed" => "compression"}
    })
    |> Repo.insert!()
  end

  defp flunk_if_terminal_without_intent(process, signal_id, expected, intent_check) do
    case ai_message_for_signal_latest(signal_id) do
      %Message{status: "complete"} = message ->
        completed? =
          match?(%Signal{completed_at: %DateTime{}}, Repo.get(Signal, signal_id))

        if completed? and not intent_check_present?(intent_check) do
          flunk(
            "AI message completed without #{expected}: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(signal_id))} #{inspect_process(process)}"
          )
        end

      %Message{status: "error"} = message ->
        flunk(
          "AI message failed without #{expected}: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(signal_id))} #{inspect_process(process)}"
        )

      _message ->
        :ok
    end
  end

  defp intent_check_present?(intent_check) do
    case intent_check.() do
      nil -> false
      [] -> false
      _value -> true
    end
  end

  defp poll_value(fun) do
    fun.()
  rescue
    error in DBConnection.ConnectionError ->
      if transient_sandbox_checkout_error?(error) do
        nil
      else
        reraise error, __STACKTRACE__
      end
  end

  defp with_transient_db_retry(process, deadline, fun) do
    fun.()
  rescue
    error in DBConnection.ConnectionError ->
      if transient_sandbox_checkout_error?(error) do
        receive_or_wait(process, deadline, fn ->
          with_transient_db_retry(process, deadline, fun)
        end)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp transient_sandbox_checkout_error?(%DBConnection.ConnectionError{} = error) do
    message = Exception.message(error)

    String.contains?(message, "could not checkout the connection") and
      String.contains?(message, "connection not available")
  end

  defp ai_message_for_signal(signal_id),
    do: ai_message_for_signal_latest(signal_id)

  defp ai_message_for_signal_latest(signal_id) do
    Message
    |> where(
      [message],
      fragment("?#>>'{request_metadata,signal_id}'", message.metadata) == ^signal_id
    )
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp final_ai_message_for_signal(signal_id) do
    with %Signal{final_response_id: id} = signal when is_binary(id) <-
           Repo.get(Signal, signal_id),
         {:ok, %{final_response: response}} <-
           Ankole.Sessions.ModelHistory.load_turn_chain(
             %Ankole.Sessions.RunRef{
               agent_uid: signal.agent_uid,
               session_id: signal.session_id,
               signal_id: signal.id
             },
             id
           ) do
      response
    else
      _not_adopted -> nil
    end
  end

  defp mirrored_latest_final_reply_for_signal(signal_id) do
    with %Intent{} = intent <- primary_final_intent(signal_id),
         %Message{} = message <- Repo.get(Message, intent.ai_message_id),
         %{message: %ConversationMessage{}} = entry <- primary_final_entry(intent) do
      {entry, message}
    else
      _missing -> nil
    end
  end

  # The final intent is the anchor, not the AI message. A steer that reached the
  # Worker owns the reply and its intent, while the AI message stays recorded
  # against the Turn that produced it, so the two can sit under different
  # Signals. `ai_message_id` on the intent is the link between them.
  defp primary_final_intent(signal_id) do
    Intent
    |> where([intent], intent.source_signal_id == ^signal_id)
    |> Repo.all()
    |> Enum.find(fn intent ->
      metadata = get_in(intent.payload, ["metadata"]) || %{}

      metadata["source"] == "ai_gateway_final_reply" and
        get_in(metadata, ["delivery_target", "primary"]) != false
    end)
  end

  defp primary_final_entry(%Intent{} = intent) do
    case intent.created_provider_message_id || intent.target_provider_message_id do
      provider_message_id when is_binary(provider_message_id) ->
        External.get_message(Repo, intent.conversation_id, provider_message_id)

      nil ->
        Repo.all(
          from message in ConversationMessage,
            join: ref in ExternalMessageRef,
            on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
            where:
              ref.ai_message_id == ^intent.ai_message_id and
                ref.conversation_id == ^intent.conversation_id,
            select: %{message: message, external_ref: ref}
        )
        |> Enum.find(fn %{external_ref: ref} ->
          ref.metadata["signal_id"] == intent.source_signal_id and
            get_in(ref.metadata, ["delivery_target", "primary"]) != false
        end)
    end
  end

  defp ai_message_status("succeeded"), do: "complete"
  defp ai_message_status("failed"), do: "error"
  defp ai_message_status("cancelled"), do: "error"
  defp ai_message_status(status), do: status

  defp message_response(%Message{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "response", metadata)
  end

  defp durable_commit_state(signal_id) do
    event = Repo.get(Signal, signal_id)

    driver =
      if event do
        case Ankole.Sessions.driver_pid(event) do
          :undefined ->
            :absent

          pid ->
            try do
              {state, data} = :sys.get_state(pid, 1_000)

              %{
                state: state,
                tasks:
                  Enum.map(data.tasks, fn {_ref, {kind, task}} ->
                    {kind, Process.info(task, :current_stacktrace)}
                  end)
              }
            catch
              :exit, reason -> {:unavailable, reason}
            end
        end
      end

    %{
      driver: driver,
      signals:
        Signal
        |> where([event], event.id == ^signal_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :provider_message_id,
            :completed_at,
            :input_state,
            :attempt_count,
            :last_attempt_at
          ])
        ),
      receipts:
        Ankole.Sessions.Receipts
        |> where(
          [receipt],
          receipt.agent_uid in subquery(
            from event in Signal, where: event.id == ^signal_id, select: event.agent_uid
          )
        )
        |> Repo.all()
        |> Enum.map(&Map.take(&1, [:response_id, :call_id, :session_id, :inserted_at])),
      intents:
        Intent
        |> where([intent], intent.source_signal_id == ^signal_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :outbound_key,
            :source_signal_id,
            :ai_message_id,
            :reply_to_provider_message_id,
            :target_provider_message_id,
            :operation,
            :status,
            :payload
          ])
        )
    }
  end

  defp run_due_jobs do
    now = DateTime.utc_now(:microsecond)
    Oban.drain_queue(queue: :conversations, with_scheduled: now, with_limit: 20)
    Oban.drain_queue(queue: :outbox, with_scheduled: now, with_limit: 20)
  end

  defp receive_or_wait(process, deadline, next) do
    run_due_jobs()

    if System.monotonic_time(:millisecond) > deadline do
      debug =
        case Process.get(:ankole_e2e_timeout_debug) do
          fun when is_function(fun, 0) -> " #{fun.()}"
          _other -> ""
        end

      flunk("worker e2e timed out:#{debug} #{inspect_process(process)}")
    end

    receive do
      {:fake_llm_request, _kind, _count, _request} ->
        next.()

      {:fake_feishu, _event} ->
        next.()
    after
      50 ->
        next.()
    end
  end

  # Docker failures also include the container log.
  defp inspect_process(%{kind: :docker, agent_uid: agent_uid} = container) do
    "#{inspect_worker(agent_uid)} logs=#{inspect(Ankole.E2E.DockerWorker.logs(container), printable_limit: :infinity)}"
  end

  defp inspect_process(%{agent_uid: agent_uid}), do: inspect_worker(agent_uid)

  defp inspect_worker(agent_uid) do
    row =
      case Repo.get(AgentWorker, agent_uid) do
        %AgentWorker{} = worker ->
          Map.take(worker, [:state, :generation, :transport_route, :drain_reason, :last_error])

        nil ->
          nil
      end

    "agent_uid=#{agent_uid} worker=#{inspect(row)}"
  end
end
