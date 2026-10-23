defmodule Ankole.Workflow.Lifecycle do
  @moduledoc """
  Owns workflow creation, completion, and revocation.

  The `_in_tx` functions run in the transaction of their caller. The
  `Ankole.Workflow` generic actions and the Sessions transactions call them.
  """
  require Ash.Query
  alias Ankole.BackgroundAgentJobs
  alias Ankole.I18n
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  alias Ankole.Workflow.WorkerConfig
  @supported_create_fields ~w(
    agent_uid
    args
    concurrency
    max_agent_calls
    model_profile
    owner_session_id
    reply_route
    script
    source_signal_id
    source_tool_call_id
    title
  )
  @live_call [:queued, :running, :sleeping]
  @workflow_wakeup_notice_keys %{
    "workflow.run.completed" => "workflow_dead_letter_completed",
    "workflow.run.failed" => "workflow_dead_letter_failed"
  }

  def dead_letter_notice_text(%Signal{type: type} = event)
      when is_map_key(@workflow_wakeup_notice_keys, type) do
    data = event.data
    counts = data["counts"] || %{}

    detail =
      [
        Ankole.Workflow.Queries.text_value(data["result_preview"]),
        Ankole.Workflow.Queries.workflow_failure_notice_lines(data["failure_summaries"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    I18n.t(
      "conversations.delivery.reply.#{Map.fetch!(@workflow_wakeup_notice_keys, type)}",
      %{
        "run_id" => data["run_id"] || 0,
        "title" => Ankole.Workflow.Queries.text_value(data["title"]) || "",
        "succeeded" => counts["succeeded"] || 0,
        "failed" => counts["failed"] || 0,
        "total" => counts["total"] || 0,
        "detail" => detail
      }
    )
  end

  def dead_letter_notice_text(%Signal{}) do
    nil
  end

  @doc """
  Does the post-commit work of a committed task or run transition.

  A released task slot wakes the next capacity waiter (`Mail.release_capacity/1`).
  Then the terminal cleanup of `cleanup_committed/1` runs.
  """
  def cleanup_terminal_transition({:ok, %{run: %Run{} = run, released_slot?: true}} = result) do
    with {:ok, :released} <- Ankole.Workflow.Mail.release_capacity(run) do
      cleanup_committed(result)
    end
  end

  def cleanup_terminal_transition(result), do: cleanup_committed(result)

  @doc """
  Cleans up a committed terminal run, or stops the turns of cancelled tasks.

  When an action already releases its task slot in `after_commit`, its caller
  uses this function instead of `cleanup_terminal_transition/1`.
  """
  def cleanup_committed({:ok, %{run: %Run{status: status} = run} = result})
      when status in [:completed, :failed, :cancelled] do
    Repo.assert_outside_transaction!()

    if status == :cancelled do
      RunServer.stop_replay(run.id)
    end

    case cleanup_terminal_run(run) do
      {:ok, cleaned_run} ->
        {:ok, result |> Map.put(:run, cleaned_run) |> Map.put(:cleanup_errors, [])}

      {:error, {:workflow_terminal_cleanup_failed, cleanup_errors}} ->
        {:ok, Map.put(result, :cleanup_errors, cleanup_errors)}
    end
  end

  def cleanup_committed(
        {:ok, %{run: %Run{} = run, running_session_ids: running_session_ids} = result}
      )
      when is_list(running_session_ids) do
    Repo.assert_outside_transaction!()
    cleanup_errors = stop_running_task_turns(run, running_session_ids)
    {:ok, Map.put(result, :cleanup_errors, cleanup_errors)}
  end

  def cleanup_committed(result), do: result

  def cleanup_terminal_run(%Run{cleanup_completed_at: %DateTime{}} = run) do
    {:ok, run}
  end

  def cleanup_terminal_run(%Run{status: status} = run)
      when status in [:completed, :failed, :cancelled] do
    Repo.assert_outside_transaction!()
    sessions = Ankole.Workflow.Queries.task_sessions(run.id)

    cancelled_session_ids =
      for {session_id, :cancelled} <- sessions do
        session_id
      end

    all_session_ids = Enum.map(sessions, &elem(&1, 0))

    cleanup_errors =
      stop_running_task_turns(run, cancelled_session_ids) ++
        stop_delegated_jobs(run, all_session_ids)

    case cleanup_errors do
      [] ->
        case complete_terminal_cleanup(run.id, DateTime.utc_now(:microsecond)) do
          {:ok, cleaned_run} ->
            {:ok, cleaned_run}

          {:error, reason} ->
            {:error, {:workflow_terminal_cleanup_failed, [%{run_id: run.id, reason: reason}]}}
        end

      errors ->
        {:error, {:workflow_terminal_cleanup_failed, errors}}
    end
  end

  # One transaction stops every task. A failure gives the same reason for each
  # Session, and the next cleanup tries all of them again.
  defp stop_running_task_turns(_run, []), do: []

  defp stop_running_task_turns(run, session_ids) do
    now = DateTime.utc_now(:microsecond)

    with true <-
           Ankole.Workflow.Replay.valid_reply_route?(run.reply_route || %{}) ||
             {:error, :workflow_reply_route_binding_missing},
         {:ok, _events} <-
           Ankole.Signals.accept_all(Enum.map(session_ids, &stop_event(run, &1, now))) do
      []
    else
      {:error, reason} -> Enum.map(session_ids, &%{session_id: &1, reason: reason})
    end
  end

  defp stop_event(run, session_id, now) do
    reply_route = run.reply_route || %{}
    call_id = String.replace_prefix(session_id, Ankole.Workflow.Queries.task_session_prefix(), "")
    source_event_id = "workflow:call:#{call_id}:stop"
    binding_name = Map.get(reply_route, "binding_name")

    %{
      producer: :kernel,
      source: "control-plane://workflow",
      id: source_event_id,
      type: "command.stop",
      subject: "workflow-call:#{call_id}",
      time: DateTime.to_iso8601(now),
      available_at: now,
      target: %{agent_uid: run.agent_uid, session_id: session_id},
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(run),
      reply_route: %{
        binding_name: binding_name,
        conversation_id: nil,
        provider_thread_id: nil,
        provider_message_id: nil
      },
      data: %{
        "command" => %{
          "argsText" => task_stop_reason(run.status),
          "cancel_requested_by" => "workflow"
        }
      }
    }
  end

  defp task_stop_reason(:cancelled) do
    "Workflow cancelled"
  end

  defp task_stop_reason(status) do
    "Workflow ended with status #{status}"
  end

  defp stop_delegated_jobs(%Run{} = run, session_ids) do
    session_ids
    |> BackgroundAgentJobs.live_job_ids_for_owner_sessions(run.agent_uid)
    |> Enum.flat_map(fn job_id ->
      case BackgroundAgentJobs.request_stop(job_id, %{
             "agent_uid" => run.agent_uid,
             "cancel_requested_by" => "workflow:#{run.id}"
           }) do
        {:ok, result} ->
          Ankole.Sessions.stop_job_turn(result.job, result.turn)
          []

        {:error, reason} ->
          [%{job_id: job_id, reason: reason}]
      end
    end)
  end

  @doc "Creates or finds the run of one Workflow tool call and wakes its owner process."
  def create_with_dispatch_in_tx(repo, attrs) when is_map(attrs) do
    with :ok <- validate_string_keys(attrs),
         :ok <- reject_unsupported_fields(attrs),
         {:ok, agent_uid} <-
           Principals.normalize_uid(Ankole.Attrs.optional_text(Map.get(attrs, "agent_uid"))),
         {:ok, owner_session_id} <- required_text(attrs, "owner_session_id"),
         {:ok, source_tool_call_id} <- required_text(attrs, "source_tool_call_id"),
         {:ok, reply_route} <- reply_route(attrs),
         {:ok, concurrency} <-
           bounded_limit(attrs, "concurrency", WorkerConfig.max_concurrency_per_run()),
         {:ok, max_agent_calls} <-
           bounded_limit(attrs, "max_agent_calls", WorkerConfig.max_agent_calls_per_run()) do
      attrs =
        attrs
        |> Map.put("agent_uid", agent_uid)
        |> Map.put("owner_session_id", owner_session_id)
        |> Map.put("source_tool_call_id", source_tool_call_id)
        |> Map.put("reply_route", reply_route)
        |> Map.put("concurrency", concurrency)
        |> Map.put("max_agent_calls", max_agent_calls)
        |> Map.put_new("args", %{})
        |> Map.put("error", %{})

      persist_in_tx(repo, attrs)
    end
  end

  defp persist_in_tx(repo, attrs) do
    attrs = Ankole.Principals.WorkAccess.inherit(repo, attrs)

    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
         :ok <- lock_idempotency(repo, attrs) do
      case find_existing(attrs) do
        {:ok, %Run{status: :running} = run} ->
          with :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(repo, run.id) do
            {:ok, %{run: run}}
          end

        {:ok, %Run{} = run} ->
          {:ok, %{run: run}}

        {:ok, nil} ->
          with {:ok, run} <- Ankole.Ash.create(Run, :create_run, attrs),
               :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(repo, run.id) do
            {:ok, %{run: run}}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp find_existing(attrs) do
    Run
    |> Ash.Query.filter(
      agent_uid == ^attrs["agent_uid"] and owner_session_id == ^attrs["owner_session_id"] and
        source_tool_call_id == ^attrs["source_tool_call_id"]
    )
    |> Ankole.Ash.read_one()
  end

  defp lock_idempotency(repo, attrs) do
    key =
      [
        "workflow:create",
        attrs["agent_uid"],
        attrs["owner_session_id"],
        attrs["source_tool_call_id"]
      ]
      |> Enum.join(":")

    case Ankole.AdvisoryLock.lock(repo, key) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_string_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(not is_binary(&1))) do
      nil -> :ok
      key -> {:error, {:invalid_workflow_attribute_key, key}}
    end
  end

  defp reject_unsupported_fields(attrs) do
    case Map.keys(attrs) |> Enum.reject(&(&1 in @supported_create_fields)) |> Enum.sort() do
      [] -> :ok
      fields -> {:error, {:unsupported_workflow_create_fields, fields}}
    end
  end

  defp reply_route(attrs) do
    case Map.get(attrs, "reply_route") do
      route when is_map(route) ->
        with :ok <- validate_string_keys(route) do
          case Ecto.UUID.cast(Map.get(route, "conversation_id")) do
            {:ok, id} ->
              {:ok, Map.put(route, "conversation_id", id)}

            :error ->
              with {:ok, binding_name} <- required_text(route, "binding_name") do
                {:ok, Map.put(route, "binding_name", binding_name)}
              end
          end
        end

      _value ->
        {:error, :invalid_workflow_reply_route}
    end
  end

  defp bounded_limit(attrs, "concurrency", configured_maximum) do
    case Map.get(attrs, "concurrency") do
      nil -> {:ok, configured_maximum}
      value when is_integer(value) and value in 1..32 -> {:ok, min(value, configured_maximum)}
      _value -> {:error, {:invalid_workflow_concurrency, %{min: 1, max: 32}}}
    end
  end

  defp bounded_limit(attrs, "max_agent_calls", configured_maximum) do
    case Map.get(attrs, "max_agent_calls") do
      nil -> {:ok, configured_maximum}
      value when is_integer(value) and value in 1..1024 -> {:ok, min(value, configured_maximum)}
      _value -> {:error, {:invalid_workflow_max_agent_calls, %{min: 1, max: 1024}}}
    end
  end

  defp required_text(attrs, "owner_session_id") do
    Ankole.Attrs.required_text(
      Map.get(attrs, "owner_session_id"),
      :workflow_owner_session_id_required
    )
  end

  defp required_text(attrs, "source_tool_call_id") do
    Ankole.Attrs.required_text(
      Map.get(attrs, "source_tool_call_id"),
      :workflow_source_tool_call_id_required
    )
  end

  defp required_text(attrs, "binding_name") do
    {:ok, Ankole.Attrs.optional_text(Map.get(attrs, "binding_name"))}
  end

  defp required_text(attrs, key) do
    Ankole.Attrs.required_text(Map.get(attrs, key), :workflow_required_text_missing)
  end

  defp complete_terminal_cleanup(run_id, %DateTime{} = completed_at),
    do:
      Ankole.Ash.run_action(Run, :complete_cleanup, %{run_id: run_id, completed_at: completed_at})

  @doc false
  def complete_cleanup_in_tx(repo, run_id, %DateTime{} = completed_at)
      when is_integer(run_id) and run_id > 0 do
    case Ankole.Workflow.Slot.lock_run(repo, run_id) do
      %Run{cleanup_completed_at: %DateTime{}} = run ->
        {:ok, run}

      %Run{status: status} = run when status in [:completed, :failed, :cancelled] ->
        Ankole.Ash.update(run, :update_metadata, %{cleanup_completed_at: completed_at})

      %Run{status: :running} ->
        {:error, :workflow_run_not_terminal}

      nil ->
        {:error, :workflow_not_found}
    end
  end

  def cancel_in_tx(repo, run_id, agent_uid) do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(repo, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(repo, run_id, agent_uid) do
      if run.status == :running do
        completed_at = DateTime.utc_now()

        with {:ok, running_ids} <- cancel_live_calls_in_tx(repo, run.id, completed_at),
             {:ok, run} <-
               Ankole.Ash.update(run, :stop, %{completed_at: completed_at, error: %{}}),
             :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(repo, run.id) do
          {:ok, %{run: run, running_session_ids: running_ids}}
        end
      else
        {:ok, %{run: run, running_session_ids: []}}
      end
    else
      nil -> {:error, :workflow_not_found}
      {:error, _reason} = error -> error
    end
  end

  def conclude_run_in_tx(repo, run, status, result_text, error, completed_at) do
    with {:ok, running_ids} <- cancel_live_calls_in_tx(repo, run.id, completed_at),
         {:ok, run} <-
           Ankole.Ash.update(run, run_action(status), %{
             result_text: result_text,
             error: error,
             completed_at: completed_at
           }),
         {:ok, wakeup_event} <- Ankole.Workflow.Mail.append_wakeup_event(repo, run, completed_at),
         :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(repo, run.id) do
      {:ok, %{run: run, wakeup_event: wakeup_event, running_session_ids: running_ids}}
    end
  end

  defp cancel_live_calls_in_tx(repo, run_id, _updated_at) do
    calls = Ankole.Workflow.Slot.lock_run_calls(repo, run_id)

    running_ids =
      for %AgentCall{status: :running, id: id} <- calls do
        Ankole.Workflow.Queries.task_session_id(id)
      end

    live_ids = for %AgentCall{status: status, id: id} <- calls, status in @live_call, do: id

    with {:ok, _calls} <-
           transition_where(AgentCall, live_ids, :cancel_live_calls, %{result: nil, error: %{}}) do
      {:ok, running_ids}
    end
  end

  defp run_action(:completed) do
    :complete
  end

  defp run_action(:failed) do
    :fail
  end

  defp run_action(:cancelled) do
    :stop
  end

  def update_run_memo_bytes(_repo, %Run{memo_bytes: memo_bytes} = run, memo_bytes) do
    {:ok, run}
  end

  def update_run_memo_bytes(_repo, run, memo_bytes) do
    Ankole.Ash.update(run, :update_metadata, %{memo_bytes: memo_bytes})
  end

  @doc "Stops a running run whose Human access was revoked, in the caller's transaction."
  def revoke_run_in_tx(_repo, %Run{} = run) do
    run_id = run.id
    stop_runs_in_tx(Ash.Query.filter(Run, id == ^run_id), DateTime.utc_now())
    {:ok, %Run{} = run} = Run |> Ash.Query.filter(id == ^run_id) |> Ankole.Ash.read_one()
    run
  end

  @doc "Stops the runs of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(_repo, uid, version, now) do
    Run
    |> Ash.Query.filter(human_uid == ^uid and human_access_version < ^version)
    |> stop_runs_in_tx(now)
  end

  defp stop_runs_in_tx(runs, now) do
    {:ok, candidates} =
      runs |> Ash.Query.filter(status == :running) |> Ash.Query.select([:id]) |> Ankole.Ash.read()

    ids = Enum.map(candidates, & &1.id)

    {:ok, live} =
      runs
      |> Ash.Query.filter(status == :running and id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read(lock_identity: {"workflow_runs", ids})

    ids = Enum.map(live, & &1.id)

    {:ok, stopped} =
      transition_where(Run, ids, :stop_runs, %{
        completed_at: now,
        cleanup_completed_at: now,
        error: %{"code" => "human_access_revoked"}
      })

    {:ok, calls} =
      AgentCall
      |> Ash.Query.filter(run_id in ^ids and status in [:queued, :sleeping])
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read()

    {:ok, _calls} =
      transition_where(AgentCall, Enum.map(calls, & &1.id), :cancel_live_calls, %{
        error: %{"code" => "human_access_revoked"}
      })

    {length(stopped), nil}
  end

  defp transition_where(_resource, [], _action, _attrs), do: {:ok, []}

  defp transition_where(resource, ids, action, attrs),
    do: resource |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.update_where(action, attrs)
end
