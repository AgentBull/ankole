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
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
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
    current_leaf = current_visible_leaf(conversation_id)

    old_user =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        "Compression seed: the release codename is ANKOLE_REAL_E2E.",
        previous_message_id(current_leaf)
      )

    old_assistant =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "assistant",
        "Compression seed recorded: ANKOLE_REAL_E2E.",
        old_user.id
      )

    current_tail_id =
      case current_leaf do
        %Message{} = leaf ->
          leaf
          |> Message.changeset(%{previous_message_id: old_assistant.id})
          |> Repo.update!()

          leaf.id

        nil ->
          old_assistant.id
      end

    _recent_tail =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        String.duplicate("Recent tail retained after compression. ", 2_500),
        current_tail_id
      )

    [old_user.id, old_assistant.id]
  end

  @doc """
  Fetches the checkback row created by a worker schedule tool call.
  """
  @spec checkback_by_idempotency!(String.t(), String.t()) :: ScheduledEvent.t()
  def checkback_by_idempotency!(agent_uid, idempotency_key) do
    Repo.one!(
      from(event in ScheduledEvent,
        where: event.agent_uid == ^String.downcase(agent_uid),
        where: event.kind == "check_back_later",
        where: event.idempotency_key == ^idempotency_key
      )
    )
  end

  @doc """
  Fetches the cron schedule row created by a worker cron tool call.
  """
  @spec cron_schedule_by_idempotency!(String.t(), String.t()) :: CronSchedule.t()
  def cron_schedule_by_idempotency!(agent_uid, idempotency_key) do
    Repo.one!(
      from(schedule in CronSchedule,
        where: schedule.agent_uid == ^String.downcase(agent_uid),
        where: schedule.idempotency_key == ^idempotency_key
      )
    )
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
    case fun.() do
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
    case {Repo.get(ActorEvent, actor_event_id), final_ai_message_for_actor_event(actor_event_id)} do
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
  Waits for the final IM mirror of one completed actor event.

  Ordinary streamed AI replies do not produce durable outbox rows under the
  stateful AIGateway plan. They become provider-visible through the live
  AIReplyPreview path, then are mirrored as `signal_gateway_entries.ai_message_id`.
  """
  @spec wait_for_completed_final_reply(map() | port(), Ecto.UUID.t(), integer()) ::
          {:ok, Entry.t(), Message.t()}
  def wait_for_completed_final_reply(process, actor_event_id, deadline) do
    with {:ok, message} <-
           wait_for_completed_actor_event_message(process, actor_event_id, deadline),
         {:ok, reply} <-
           wait_for_final_mirror(process, message.id, deadline) do
      {:ok, reply, message}
    end
  end

  @doc """
  Waits for the outbox row committed for one actor event and AI message.
  """
  @spec wait_for_outbox_for_input(map() | port(), Ecto.UUID.t(), integer(), Ecto.UUID.t()) ::
          {:ok, OutboxEntry.t()}
  def wait_for_outbox_for_input(process, source_actor_event_id, deadline, ai_message_id) do
    case Repo.get_by(OutboxEntry,
           source_actor_event_id: source_actor_event_id,
           ai_message_id: ai_message_id
         ) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        flunk_if_terminal_without_outbox(
          process,
          source_actor_event_id,
          "outbox for source_actor_event_id=#{source_actor_event_id}",
          fn ->
            Repo.get_by(OutboxEntry,
              source_actor_event_id: source_actor_event_id,
              ai_message_id: ai_message_id
            )
          end
        )

        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox_for_input(process, source_actor_event_id, deadline, ai_message_id)
        end)
    end
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
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> Repo.all()
  end

  defp insert_transcript_message!(agent_uid, conversation_id, role, text, previous_message_id) do
    %Message{}
    |> Message.changeset(%{
      agent_uid: agent_uid,
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

  defp current_visible_leaf(conversation_id) do
    case StatefulResponses.latest_visible_leaf(conversation_id) do
      nil -> nil
      message_id -> Repo.get!(Message, message_id)
    end
  end

  defp previous_message_id(%Message{previous_message_id: previous_message_id}),
    do: previous_message_id

  defp previous_message_id(nil), do: nil

  defp worker_has_capacity?(%AgentComputerWorker{capacity: capacity, load: load}) do
    available_slots =
      integer_from_map(capacity, "available_turn_slots") ||
        case {integer_from_map(capacity, "max_turns"), integer_from_map(load, "active_turns")} do
          {max_turns, active_turns} when is_integer(max_turns) and is_integer(active_turns) ->
            max_turns - active_turns

          _value ->
            nil
        end

    case available_slots do
      slots when is_integer(slots) -> slots > 0
      nil -> true
    end
  end

  defp integer_from_map(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp integer_from_map(_map, _key), do: nil

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

  defp outbox_check_present?(outbox_check), do: not is_nil(outbox_check.())

  defp ai_message_for_actor_event(actor_event_id),
    do: ai_message_for_actor_event_latest(actor_event_id)

  defp ai_message_for_actor_event_latest(actor_event_id) do
    Message
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp final_ai_message_for_actor_event(actor_event_id) do
    Message
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> where([message], message.status == "complete")
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> Repo.all()
    |> Enum.find(&final_answer_message?/1)
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

  defp receive_port_or_wait(process, deadline, next) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk(
        "worker e2e timed out: #{inspect_process(process)} #{received_process_output(process_port(process))}"
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
