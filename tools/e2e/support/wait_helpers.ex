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
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Event
  alias Ankole.RuntimeEvents.Handlers
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

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
  Fetches the first concrete scheduled event armed for a cron schedule.
  """
  @spec cron_event_for_schedule!(Ecto.UUID.t()) :: ScheduledEvent.t()
  def cron_event_for_schedule!(cron_schedule_id) do
    Repo.one!(
      from(event in ScheduledEvent,
        where: event.kind == "cron_fire",
        where: event.cron_schedule_id == ^cron_schedule_id
      )
    )
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
  Waits until the worker projection is ready and reports available capacity.
  """
  @spec wait_for_worker_projection(String.t(), map() | port(), integer()) ::
          {:ok, AgentComputerWorker.t()}
  def wait_for_worker_projection(worker_id, process, deadline) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{status: "ready"} = worker ->
        case worker_has_capacity?(worker) do
          true ->
            {:ok, worker}

          false ->
            receive_port_or_wait(process, deadline, fn ->
              wait_for_worker_projection(worker_id, process, deadline)
            end)
        end

      _worker_or_nil ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_worker_projection(worker_id, process, deadline)
        end)
    end
  end

  @doc """
  Waits for the AI message associated with one actor event to reach a status.

  Accepts the runtime-facing status names (`"succeeded"`, `"failed"`,
  `"cancelled"`) and maps them onto the `ai_gateway_messages` status column.
  """
  @spec wait_for_turn_status(map() | port(), Ecto.UUID.t(), String.t(), integer()) ::
          {:ok, Message.t()}
  def wait_for_turn_status(process, actor_event_id, status, deadline) do
    expected_status = ai_message_status(status)

    case ai_message_for_actor_event(actor_event_id) do
      %Message{status: ^expected_status} = message ->
        {:ok, message}

      _other ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_turn_status(process, actor_event_id, status, deadline)
        end)
    end
  end

  @doc """
  Waits until the actor event is complete and returns its latest AI message.

  A tool loop can commit an earlier function_call row with status `complete`
  while the actor event remains live. The final IM-visible answer is the latest
  complete message after `actor_events.completed_at` is written.
  """
  @spec wait_for_completed_actor_event_message(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, Message.t()}
  def wait_for_completed_actor_event_message(process, actor_event_id, deadline) do
    with_transient_db_retry(process, deadline, fn ->
      case {Repo.get(ActorEvent, actor_event_id),
            final_ai_message_for_actor_event(actor_event_id)} do
        {%ActorEvent{completed_at: %DateTime{}}, %Message{status: "complete"} = message} ->
          {:ok, message}

        {%ActorEvent{completed_at: %DateTime{}}, nil} ->
          case ai_message_for_actor_event(actor_event_id) do
            %Message{status: "error"} = message ->
              flunk(
                "actor event completed with failed AI message: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(actor_event_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
              )

            _message ->
              receive_port_or_wait(process, deadline, fn ->
                wait_for_completed_actor_event_message(process, actor_event_id, deadline)
              end)
          end

        {%ActorEvent{completed_at: %DateTime{}}, %Message{status: "error"} = message} ->
          flunk(
            "actor event completed with failed AI message: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(actor_event_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
          )

        _other ->
          receive_port_or_wait(process, deadline, fn ->
            wait_for_completed_actor_event_message(process, actor_event_id, deadline)
          end)
      end
    end)
  end

  @doc """
  Waits until `actor_events.completed_at` is written, without requiring any AI
  message (e.g. ambient silence commits a noop completion).
  """
  @spec wait_for_actor_event_completed(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, ActorEvent.t()}
  def wait_for_actor_event_completed(process, actor_event_id, deadline) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{completed_at: %DateTime{}} = event ->
        {:ok, event}

      _other ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_actor_event_completed(process, actor_event_id, deadline)
        end)
    end
  end

  @doc """
  Waits until an actor event reaches its durable dead-letter state.
  """
  @spec wait_for_actor_event_dead_letter(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, ActorEvent.t()}
  def wait_for_actor_event_dead_letter(process, actor_event_id, deadline) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{input_state: "dead_letter", dead_letter_at: %DateTime{}} = event ->
        {:ok, event}

      _other ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_actor_event_dead_letter(process, actor_event_id, deadline)
        end)
    end
  end

  @doc """
  Waits for the final IM mirror row associated with an AI message.
  """
  @spec wait_for_final_mirror(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, Entry.t()}
  def wait_for_final_mirror(process, ai_message_id, deadline) do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        {:ok, entry}

      nil ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_final_mirror(process, ai_message_id, deadline)
        end)
    end
  end

  @doc """
  Waits for the latest final IM mirror of one completed actor event.

  Ordinary streamed AI replies commit a final `ai-reply:<message_id>` outbox row.
  The e2e wait loop advances due RuntimeEvents from the durable snapshot because
  SQL sandbox tests do not commit the transaction that would release pg_notify.
  """
  @spec wait_for_completed_final_reply(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, Entry.t(), Message.t()}
  def wait_for_completed_final_reply(process, actor_event_id, deadline) do
    Process.put(
      :ankole_e2e_timeout_debug,
      fn ->
        "durable_state=#{inspect(durable_commit_state(actor_event_id))} messages=#{inspect(ai_messages_for_actor_event(actor_event_id))}"
      end
    )

    if System.monotonic_time(:millisecond) > deadline do
      flunk(
        "timed out waiting for final reply: durable_state=#{inspect(durable_commit_state(actor_event_id))} messages=#{inspect(ai_messages_for_actor_event(actor_event_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
      )
    end

    with_transient_db_retry(process, deadline, fn ->
      case {Repo.get(ActorEvent, actor_event_id),
            mirrored_latest_final_reply_for_actor_event(actor_event_id)} do
        {%ActorEvent{completed_at: %DateTime{}}, {%Entry{} = reply, %Message{} = message}} ->
          {:ok, reply, message}

        {%ActorEvent{completed_at: %DateTime{}}, nil} ->
          run_due_outbox_runtime_events()

          receive_port_or_wait(process, deadline, fn ->
            wait_for_completed_final_reply(process, actor_event_id, deadline)
          end)

        _other ->
          receive_port_or_wait(process, deadline, fn ->
            wait_for_completed_final_reply(process, actor_event_id, deadline)
          end)
      end
    end)
  end

  @doc """
  Waits for the explicit side-effect outbox row committed for one actor event
  and AI message. Plain final-reply rows use the `ai-reply:<message_id>` key and
  are handled by `wait_for_completed_final_reply/3`.
  """
  @spec wait_for_outbox_for_input(map() | port(), Ecto.UUID.t(), integer(), Ecto.UUID.t()) ::
          {:ok, OutboxEntry.t()}
  def wait_for_outbox_for_input(process, source_actor_event_id, deadline, ai_message_id) do
    case side_effect_outboxes_for_input(source_actor_event_id, ai_message_id) do
      [%OutboxEntry{} = outbox] ->
        {:ok, outbox}

      [] ->
        flunk_if_terminal_without_outbox(
          process,
          source_actor_event_id,
          "outbox for source_actor_event_id=#{source_actor_event_id}",
          fn ->
            side_effect_outboxes_for_input(source_actor_event_id, ai_message_id)
          end
        )

        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox_for_input(process, source_actor_event_id, deadline, ai_message_id)
        end)

      outboxes ->
        flunk(
          "expected one side-effect outbox for source_actor_event_id=#{source_actor_event_id} ai_message_id=#{ai_message_id}, found #{length(outboxes)}: #{inspect(Enum.map(outboxes, & &1.outbound_key))}"
        )
    end
  end

  defp side_effect_outboxes_for_input(source_actor_event_id, ai_message_id) do
    final_reply_key = "ai-reply:#{ai_message_id}"

    OutboxEntry
    |> where([outbox], outbox.source_actor_event_id == ^source_actor_event_id)
    |> where([outbox], outbox.ai_message_id == ^ai_message_id)
    |> where([outbox], outbox.outbound_key != ^final_reply_key)
    |> order_by([outbox], asc: outbox.inserted_at, asc: outbox.outbound_key)
    |> Repo.all()
  end

  @doc """
  Waits for the final outbox of one actor event without knowing the message id.

  Convenience wrapper: first waits for the actor event to complete with an AI
  message, then waits for the outbox row committed for that message.
  """
  @spec wait_for_completed_outbox(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, OutboxEntry.t(), Message.t()}
  def wait_for_completed_outbox(process, actor_event_id, deadline) do
    with {:ok, message} <-
           wait_for_completed_actor_event_message(process, actor_event_id, deadline),
         {:ok, outbox} <-
           wait_for_outbox_for_input(process, actor_event_id, deadline, message.id) do
      {:ok, outbox, message}
    end
  end

  @doc """
  Returns every AI message committed for one actor event in commit order.
  """
  @spec ai_messages_for_actor_event(Ecto.UUID.t()) :: [Message.t()]
  def ai_messages_for_actor_event(actor_event_id) do
    Message
    |> where(
      [message],
      fragment("?#>>'{request_metadata,actor_event_id}'", message.metadata) == ^actor_event_id
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

  defp worker_has_capacity?(%AgentComputerWorker{
         capacity: %{"available_turn_slots" => slots}
       })
       when is_integer(slots),
       do: slots > 0

  defp worker_has_capacity?(%AgentComputerWorker{}), do: false

  defp flunk_if_terminal_without_outbox(process, actor_event_id, expected, outbox_check) do
    case ai_message_for_actor_event_latest(actor_event_id) do
      %Message{status: "complete"} = message ->
        completed? =
          match?(%ActorEvent{completed_at: %DateTime{}}, Repo.get(ActorEvent, actor_event_id))

        if completed? and not outbox_check_present?(outbox_check) do
          flunk(
            "AI message completed without #{expected}: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(actor_event_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
          )
        end

      %Message{status: "error"} = message ->
        flunk(
          "AI message failed without #{expected}: response=#{inspect(message_response(message))} durable_state=#{inspect(durable_commit_state(actor_event_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
        )

      _message ->
        :ok
    end
  end

  defp outbox_check_present?(outbox_check) do
    case outbox_check.() do
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
        receive_port_or_wait(process, deadline, fn ->
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

  defp ai_message_for_actor_event(actor_event_id),
    do: ai_message_for_actor_event_latest(actor_event_id)

  defp ai_message_for_actor_event_latest(actor_event_id) do
    Message
    |> where(
      [message],
      fragment("?#>>'{request_metadata,actor_event_id}'", message.metadata) == ^actor_event_id
    )
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp final_ai_message_for_actor_event(actor_event_id) do
    actor_event_id
    |> final_answer_messages_for_actor_event()
    |> List.first()
  end

  defp mirrored_latest_final_reply_for_actor_event(actor_event_id) do
    case final_ai_message_for_actor_event(actor_event_id) do
      %Message{} = message ->
        case Entry
             |> where([entry], entry.ai_message_id == ^message.id)
             |> where(
               [entry],
               fragment("?#>>'{actor_event_id}'", entry.metadata) == ^actor_event_id
             )
             |> Repo.one() do
          %Entry{} = entry -> {entry, message}
          nil -> nil
        end

      nil ->
        nil
    end
  end

  defp final_answer_messages_for_actor_event(actor_event_id) do
    Message
    |> where(
      [message],
      fragment("?#>>'{request_metadata,actor_event_id}'", message.metadata) == ^actor_event_id
    )
    |> where([message], message.status == "complete")
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> Repo.all()
    |> Enum.filter(&final_answer_message?/1)
  end

  defp final_answer_message?(%Message{metadata: metadata, content: content}) do
    not tool_result_journal?(metadata) and not contains_non_final_tool_item?(content)
  end

  defp tool_result_journal?(%{"tool_result_journal" => true}), do: true
  defp tool_result_journal?(_metadata), do: false

  defp contains_non_final_tool_item?(items) when is_list(items) do
    Enum.any?(items, fn
      %{"type" => type} when type in ["function_call", "function_call_output"] ->
        true

      %{"content" => nested} when is_list(nested) ->
        contains_non_final_tool_item?(nested)

      _item ->
        false
    end)
  end

  defp contains_non_final_tool_item?(_items), do: false

  defp ai_message_status("succeeded"), do: "complete"
  defp ai_message_status("failed"), do: "error"
  defp ai_message_status("cancelled"), do: "error"
  defp ai_message_status(status), do: status

  defp message_response(%Message{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "response", metadata)
  end

  defp durable_commit_state(actor_event_id) do
    %{
      actor_events:
        ActorEvent
        |> where([event], event.id == ^actor_event_id)
        |> Repo.all()
        |> Enum.map(&Map.take(&1, [:id, :source_entry_id, :completed_at])),
      deliveries:
        ActorEventDelivery
        |> where([delivery], delivery.actor_event_id == ^actor_event_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :state,
            :worker_id,
            :transport_route,
            :activation_uid,
            :actor_epoch,
            :revision,
            :error
          ])
        ),
      activations:
        ActorSessionActivation
        |> where([activation], activation.current_actor_event_id == ^actor_event_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :activation_uid,
            :status,
            :assigned_worker_id,
            :actor_epoch,
            :revision,
            :stop_reason
          ])
        ),
      outboxes:
        OutboxEntry
        |> where([outbox], outbox.source_actor_event_id == ^actor_event_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :outbound_key,
            :source_actor_event_id,
            :ai_message_id,
            :reply_to_source_entry_id,
            :target_source_entry_id,
            :operation,
            :status,
            :payload
          ])
        )
    }
  end

  defp run_due_outbox_runtime_events do
    now = DateTime.utc_now(:microsecond)

    SignalsGateway.runtime_event_snapshot()
    |> Enum.flat_map(fn {channel, payload} -> RuntimeEvents.expand(channel, payload) end)
    |> Enum.filter(&due_outbox_event?(&1, now))
    |> Enum.each(&Handlers.handle/1)
  end

  defp due_outbox_event?(%Event{kind: :outbox_due, due_at: nil}, _now), do: true

  defp due_outbox_event?(%Event{kind: :outbox_due, due_at: %DateTime{} = due_at}, now),
    do: DateTime.compare(due_at, now) != :gt

  defp due_outbox_event?(%Event{}, _now), do: false

  defp receive_port_or_wait(process, deadline, next) do
    if System.monotonic_time(:millisecond) > deadline do
      debug =
        case Process.get(:ankole_e2e_timeout_debug) do
          fun when is_function(fun, 0) -> " #{fun.()}"
          _other -> ""
        end

      flunk(
        "worker e2e timed out:#{debug} #{inspect_process(process)} #{received_process_output(process_port(process))}"
      )
    end

    port = process_port(process)

    receive do
      {^port, {:exit_status, status}} ->
        flunk(
          "worker exited before e2e completed: #{status} #{inspect_process(process)} #{received_process_output(port)}"
        )

      {^port, {:data, data}} ->
        remember_process_output(port, data)
        next.()

      {:fake_llm_request, _kind, _count, _request} ->
        next.()

      {:fake_feishu, _event} ->
        next.()
    after
      50 ->
        next.()
    end
  end

  defp process_port(%{port: port}), do: port
  defp process_port(port) when is_port(port), do: port

  defp inspect_process(%{kind: :docker, name: name}), do: "container=#{name}"
  defp inspect_process(port) when is_port(port), do: "port=#{inspect(port)}"

  defp remember_process_output(port, data) when is_port(port) and is_binary(data) do
    key = {:worker_e2e_output, port}

    output =
      [Process.get(key, ""), data] |> IO.iodata_to_binary() |> String.slice(-48_000, 48_000)

    Process.put(key, output)
    :ok
  end

  defp received_process_output(port) when is_port(port) do
    case Process.get({:worker_e2e_output, port}, "") do
      "" -> "output=<empty>"
      output -> "output=#{inspect(output, limit: :infinity, printable_limit: :infinity)}"
    end
  end
end
