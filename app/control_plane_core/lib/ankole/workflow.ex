defmodule Ankole.Workflow do
  @moduledoc "Durable workflow operations delegated to their domain owners."
  @behaviour Ankole.Sessions.AsyncWorkUnit
  defdelegate list(agent_uid, opts \\ []), to: Ankole.Workflow.Queries
  defdelegate get(run_id, agent_uid, opts \\ []), to: Ankole.Workflow.Queries
  defdelegate task_session_id(call_id), to: Ankole.Workflow.Queries
  defdelegate parse_task_session_id(session_id), to: Ankole.Workflow.Queries
  defdelegate get_task_for_agent(call_id, agent_uid), to: Ankole.Workflow.Queries
  defdelegate dead_letter_notice_text(event), to: Ankole.Workflow.Lifecycle
  defdelegate cleanup_terminal_transition(result), to: Ankole.Workflow.Lifecycle
  defdelegate cleanup_terminal_run(run), to: Ankole.Workflow.Lifecycle
  defdelegate create_with_dispatch(attrs), to: Ankole.Workflow.Lifecycle
  defdelegate cancel_in_tx(repo, run_id, agent_uid), to: Ankole.Workflow.Lifecycle
  defdelegate revoke_run_in_tx(repo, run), to: Ankole.Workflow.Lifecycle
  defdelegate stop_human_work_in_tx(repo, human, version, now), to: Ankole.Workflow.Lifecycle

  defdelegate compensate_turn_error_in_tx(repo, event, reason, now),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate authorize_delegated_job_owner_in_tx(repo, agent_uid, owner_session_id),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate lock_task_progress_in_tx(repo, call_id, agent_uid, session_id, attempt),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate touch_running_task_in_tx(repo, call, now), to: Ankole.Workflow.TaskLifecycle

  defdelegate claim_task_in_tx(repo, call_id, agent_uid, max_running_per_agent, opts \\ []),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate submit_result_in_tx(repo, call_id, agent_uid, session_id, outcome),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate sleep_task_in_tx(repo, call_id, agent_uid, session_id, params),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate fail_unstarted_task_in_tx(repo, call_id, agent_uid, code, summary, available_at),
    to: Ankole.Workflow.TaskLifecycle

  defdelegate model_unavailable_in_tx(
                repo,
                call_id,
                agent_uid,
                session_id,
                profile,
                reason,
                available_at
              ),
              to: Ankole.Workflow.TaskLifecycle

  defdelegate commit_replay_pending(run_id, pending_calls, expected_memo_length),
    to: Ankole.Workflow.Replay

  defdelegate complete_replay(run_id, result_text, expected_memo_length),
    to: Ankole.Workflow.Replay

  defdelegate fail_replay(run_id, code, summary, expected_memo_length), to: Ankole.Workflow.Replay

  defdelegate send_task_message(run_id, call_seq, agent_uid, message, source_tool_call_id),
    to: Ankole.Workflow.Mail

  defdelegate defer_task_event(signal, available_at, reason), to: Ankole.Workflow.Mail
  defdelegate reconcile_run_wakeups(), to: Ankole.Workflow.Recovery
  defdelegate reconcile_stale_tasks(run_id, cutoff, reconciled_at), to: Ankole.Workflow.Recovery
end
