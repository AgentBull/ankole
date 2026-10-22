defmodule Ankole.Workflow.Mail do
  @moduledoc "Owns workflow messages and post-commit capacity wakeups."
  import Ecto.Query, warn: false
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Text
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  @max_task_message_bytes 8192

  def send_task_message(run_id, call_seq, agent_uid, message, source_tool_call_id)
      when is_integer(run_id) and is_integer(call_seq) and call_seq >= 0 and is_binary(agent_uid) and
             is_binary(message) and is_binary(source_tool_call_id) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- validate_task_message(message),
         :ok <- validate_source_tool_call_id(source_tool_call_id) do
      Repo.transact(fn repo ->
        with %Run{} = run <-
               repo.one(
                 from(run in Run, where: run.id == ^run_id and run.agent_uid == ^agent_uid)
               ),
             %AgentCall{} = call <-
               repo.one(
                 from(call in AgentCall,
                   where: call.run_id == ^run_id and call.call_seq == ^call_seq
                 )
               ),
             :ok <- ensure_task_message_target(run, call),
             {:ok, event} <-
               append_task_message_event(repo, run, call, message, source_tool_call_id, now) do
          {:ok, %{call: call, run: run, event: event}}
        else
          nil -> {:error, :workflow_task_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp validate_task_message(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" -> {:error, :invalid_workflow_task_message}
      byte_size(message) > @max_task_message_bytes -> {:error, :workflow_task_message_too_large}
      true -> :ok
    end
  end

  defp validate_source_tool_call_id(value) do
    if String.trim(value) == "" do
      {:error, :invalid_workflow_source_tool_call_id}
    else
      :ok
    end
  end

  defp ensure_task_message_target(%Run{status: :running}, %AgentCall{status: status})
       when status in [:queued, :running, :sleeping] do
    :ok
  end

  defp ensure_task_message_target(%Run{status: :running}, %AgentCall{status: status}) do
    {:error, {:workflow_task_terminal, status}}
  end

  defp ensure_task_message_target(%Run{status: status}, _call) do
    {:error, {:workflow_run_terminal, status}}
  end

  defp append_task_message_event(repo, run, call, message, source_tool_call_id, now) do
    source_event_id = "workflow:call:#{call.id}:msg:#{source_tool_call_id}"
    reply_route = run.reply_route || %{}
    binding_name = Map.get(reply_route, "binding_name")

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://workflow",
      id: source_event_id,
      type: "workflow.task.message",
      subject: "workflow-call:#{call.id}",
      time: DateTime.to_iso8601(now),
      available_at: now,
      target: %{
        agent_uid: run.agent_uid,
        session_id: Ankole.Workflow.Queries.task_session_id(call.id)
      },
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(run),
      reply_route: %{
        binding_name: binding_name,
        conversation_id: nil,
        provider_thread_id: nil,
        provider_message_id: nil
      },
      data: %{
        "run_id" => run.id,
        "call_id" => call.id,
        "call_seq" => call.call_seq,
        "message" => message
      }
    })
  end

  def defer_task_event(%Signal{} = signal, %DateTime{} = available_at, :agent_capacity) do
    Repo.transact(fn repo ->
      with {:ok, call_id} <- Ankole.Workflow.Queries.parse_task_session_id(signal.session_id),
           {:ok, {_run, call}} <-
             Ankole.Workflow.TaskLifecycle.lock_task_in_tx(repo, call_id, signal.agent_uid),
           :ok <- Queue.lock_session_in_tx(repo, signal.agent_uid, signal.session_id),
           %Signal{} = current <- Ankole.Signals.lock_signal_in_tx(repo, signal.id) do
        if current.status not in [:queued, :running] do
          {:ok, current}
        else
          with {:ok, _call} <-
                 Ankole.Ash.update(call, :defer_capacity, %{
                   wake_kind: :agent_capacity,
                   wake_at: available_at
                 }),
               {:ok, event} <-
                 current |> Ankole.Ash.update(:defer, %{available_at: available_at}),
               :ok <-
                 Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
                   repo,
                   %{agent_uid: event.agent_uid, session_id: event.session_id},
                   available_at
                 ) do
            {:ok, event}
          end
        end
      else
        nil -> {:error, :workflow_task_event_not_found}
        error -> error
      end
    end)
  end

  def append_dispatch_event(repo, run, call, inserted_at) do
    source_event_id = "workflow:call:#{call.id}:dispatch"
    reply_route = run.reply_route || %{}
    arguments = call.arguments
    binding_name = Map.get(reply_route, "binding_name")

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://workflow",
      id: source_event_id,
      type: "workflow.task.dispatch",
      subject: "workflow-call:#{call.id}",
      time: DateTime.to_iso8601(inserted_at),
      available_at: inserted_at,
      target: %{
        agent_uid: run.agent_uid,
        session_id: Ankole.Workflow.Queries.task_session_id(call.id)
      },
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(run),
      reply_route: %{
        binding_name: binding_name,
        conversation_id: nil,
        provider_thread_id: nil,
        provider_message_id: nil
      },
      data: %{
        "run_id" => run.id,
        "call_id" => call.id,
        "call_seq" => call.call_seq,
        "prompt" => Map.fetch!(arguments, "prompt"),
        "label" => call.label,
        "model_profile" => call.model_profile || run.model_profile,
        "schema" => Map.get(arguments, "schema", %{"type" => "string"}),
        "attempts" => call.attempts
      }
    })
  end

  def append_wakeup_event(repo, %Run{status: status} = run, completed_at)
      when status in [:completed, :failed] do
    event_type = "workflow.run.#{status}"
    source_event_id = "workflow:#{run.id}:#{status}"
    reply_route = run.reply_route || %{}
    payload = wakeup_payload(run, source_event_id, event_type, completed_at, repo)

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: payload["source"],
      id: source_event_id,
      type: event_type,
      subject: payload["subject"],
      time: completed_at,
      data: payload["data"],
      target: %{agent_uid: run.agent_uid, session_id: run.owner_session_id},
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(run),
      reply_route: reply_route
    })
  end

  def append_wakeup_event(_repo, %Run{}, _completed_at) do
    {:ok, nil}
  end

  defp wakeup_payload(run, source_event_id, event_type, completed_at, repo) do
    counts = Ankole.Workflow.Queries.counts(repo, run.id)

    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://workflow",
      "subject" => "workflow:#{run.id}",
      "time" => DateTime.to_iso8601(completed_at),
      "type" => event_type,
      "data" => %{
        "run_id" => run.id,
        "title" => run.title,
        "status" => Atom.to_string(run.status),
        "counts" => Map.take(counts, ["total", "succeeded", "failed"]),
        "failure_summaries" => Ankole.Workflow.Queries.failure_summaries(repo, run.id),
        "result_preview" => Text.utf8_prefix(run.result_text || "", 2048),
        "reply_route" => run.reply_route || %{}
      }
    }
  end

  def append_wake_event(repo, run, call, now) do
    source_event_id = "workflow:call:#{call.id}:wake:#{call.wake_count}"
    reply_route = run.reply_route || %{}
    binding_name = Map.get(reply_route, "binding_name")

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://workflow",
      id: source_event_id,
      type: "workflow.task.wakeup",
      subject: "workflow-call:#{call.id}",
      time: DateTime.to_iso8601(now),
      available_at: call.wake_at,
      target: %{
        agent_uid: run.agent_uid,
        session_id: Ankole.Workflow.Queries.task_session_id(call.id)
      },
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(run),
      reply_route: %{
        binding_name: binding_name,
        conversation_id: nil,
        provider_thread_id: nil,
        provider_message_id: nil
      },
      data: %{
        "run_id" => run.id,
        "call_id" => call.id,
        "call_seq" => call.call_seq,
        "note" => call.sleep_note,
        "wake_count" => call.wake_count,
        "wake_at" => DateTime.to_iso8601(call.wake_at)
      }
    })
  end

  def maybe_append_attention_event(_repo, _run, _call, false, _now) do
    {:ok, nil}
  end

  def maybe_append_attention_event(repo, run, call, true, now) do
    bucket = Calendar.strftime(now, "%Y%m%d%H")
    source_event_id = "workflow:#{run.id}:attention:#{bucket}"
    reply_route = run.reply_route || %{}
    binding_name = Map.get(reply_route, "binding_name")

    with {:ok, event} <-
           Ankole.Signals.accept_in_tx(repo, %{
             producer: :kernel,
             source: "control-plane://workflow",
             id: source_event_id,
             type: "workflow.run.attention",
             subject: "workflow:#{run.id}",
             time: DateTime.to_iso8601(now),
             available_at: now,
             target: %{agent_uid: run.agent_uid, session_id: run.owner_session_id},
             sender: nil,
             authorization: Ankole.Principals.WorkAccess.fields(run),
             reply_route: %{
               binding_name: binding_name,
               conversation_id: Map.get(reply_route, "conversation_id"),
               provider_thread_id: Map.get(reply_route, "provider_thread_id"),
               provider_message_id: Map.get(reply_route, "provider_message_id")
             },
             data: %{
               "run_id" => run.id,
               "title" => run.title,
               "call_seq" => call.call_seq,
               "attention_note" => call.sleep_note
             }
           }) do
      {:ok, event}
    else
      {:error, _reason} = error -> error
    end
  end

  def release_capacity(%Run{agent_uid: agent_uid}) do
    Repo.assert_outside_transaction!()

    Repo.transact(fn repo ->
      with :ok <- Ankole.Workflow.Slot.lock_agent_slots(repo, agent_uid),
           :ok <-
             wake_next_capacity_deferred_task(repo, agent_uid, DateTime.utc_now(:microsecond)),
           do: {:ok, :released}
    end)
  end

  defp wake_next_capacity_deferred_task(repo, agent_uid, now) do
    running_calls =
      from(call in AgentCall,
        where: call.agent_uid == ^agent_uid and call.status == :running,
        group_by: call.run_id,
        select: %{run_id: call.run_id, count: count(call.id)}
      )

    candidate =
      AgentCall
      |> join(:inner, [call], run in Run, on: run.id == call.run_id)
      |> join(:left, [call], running in subquery(running_calls),
        on: running.run_id == call.run_id
      )
      |> join(:inner, [call], event in Signal,
        on:
          event.agent_uid == call.agent_uid and
            fragment(
              "? = concat('wf_task:', ?::text)",
              event.session_id,
              call.id
            )
      )
      |> where(
        [call, run, running, event],
        call.agent_uid == ^agent_uid and call.status == :queued and run.status == :running and
          coalesce(running.count, 0) < run.concurrency and
          event.status in [:queued, :running] and event.available_at > ^now and
          call.wake_kind == :agent_capacity
      )
      |> order_by([call, _, _, event],
        asc: event.inserted_at,
        asc: event.queue_sequence,
        asc: call.id
      )
      |> select([call, _, _, event], %{
        run_id: call.run_id,
        call_id: call.id,
        session_id: event.session_id,
        event_id: event.id
      })
      |> limit(1)
      |> repo.one()

    case candidate do
      %{run_id: run_id, call_id: call_id, session_id: session_id, event_id: event_id} ->
        with %Run{status: :running} <- Ankole.Workflow.Slot.lock_run(repo, run_id, agent_uid),
             %AgentCall{status: :queued, wake_kind: :agent_capacity} = call <-
               Ankole.Workflow.Slot.lock_call(repo, call_id, run_id, agent_uid),
             {:ok, _call} <- Ankole.Ash.update(call, :defer_capacity, %{wake_at: now}),
             :ok <- Queue.lock_session_in_tx(repo, agent_uid, session_id),
             %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(repo, event_id) do
          wake_capacity_deferred_event(repo, event, now)
        else
          {:error, _} = error -> error
          _closed -> :ok
        end

      nil ->
        :ok
    end
  end

  defp wake_capacity_deferred_event(
         repo,
         %Signal{
           status: live_status,
           available_at: available_at
         } = event,
         now
       )
       when live_status in [:queued, :running] do
    if DateTime.after?(available_at, now) do
      with {:ok, event} <-
             event
             |> Ankole.Ash.update(:defer, %{
               available_at: now
             }),
           :ok <-
             Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
               repo,
               %{agent_uid: event.agent_uid, session_id: event.session_id},
               now
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp wake_capacity_deferred_event(_repo, %Signal{}, _now), do: :ok
end
