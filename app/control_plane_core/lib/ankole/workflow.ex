defmodule Ankole.Workflow do
  @moduledoc """
  The Workflow domain: durable program runs and their Agent calls.

  This module is the boundary API. Each write operation is a generic action
  that owns its transaction and must be the top-level call. Code that already
  runs in a transaction composes the `_in_tx` functions of the owner modules
  (`Ankole.Workflow.TaskLifecycle`, `Ankole.Workflow.Lifecycle`, and
  `Ankole.Workflow.Slot`) and calls `cleanup_terminal_transition/1` after its
  commit.

  An operation gives `{:ok, value}` or `{:error, reason}`, where `reason` is the
  domain reason or an `Ash.Error.Invalid` error for invalid attributes.
  """
  use Ankole.Ash.Domain

  @behaviour Ankole.Sessions.AsyncWorkUnit

  alias Ankole.Workflow.Lifecycle
  alias Ankole.Workflow.Queries
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  resources do
    resource Run do
      define(:get_run, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_runs, action: :read)
      define(:reauthorize_run, action: :reauthorize)
    end

    resource AgentCall do
      define(:get_agent_call, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_calls, action: :read)
    end
  end

  defdelegate list(agent_uid, opts \\ []), to: Queries
  defdelegate get(run_id, agent_uid, opts \\ []), to: Queries
  defdelegate task_session_id(call_id), to: Queries
  defdelegate parse_task_session_id(session_id), to: Queries
  defdelegate get_task_for_agent(call_id, agent_uid), to: Queries

  @impl Ankole.Sessions.AsyncWorkUnit
  defdelegate dead_letter_notice_text(event), to: Lifecycle

  @doc "Does the post-commit work of a committed task or run transition."
  defdelegate cleanup_terminal_transition(result), to: Lifecycle

  @doc "Creates or finds the run of one Workflow tool call."
  def create_with_dispatch(attrs),
    do: Ankole.Ash.run_action(Run, :create_with_dispatch, %{attrs: attrs})

  @doc "Sends an owner message to one live task of a run."
  def send_task_message(run_id, call_seq, agent_uid, message, source_tool_call_id) do
    Ankole.Ash.run_action(AgentCall, :send_task_message, %{
      run_id: run_id,
      call_seq: call_seq,
      agent_uid: agent_uid,
      message: message,
      source_tool_call_id: source_tool_call_id
    })
  end

  @doc "Defers a task Signal until the Agent has free Workflow capacity."
  def defer_task_event(signal, available_at, reason) do
    Ankole.Ash.run_action(AgentCall, :defer_task_event, %{
      signal: signal,
      available_at: available_at,
      reason: reason
    })
  end

  @doc "Commits the new Agent calls of one replay under its memo fence."
  def commit_replay_pending(run_id, pending_calls, expected_memo_length) do
    Ankole.Ash.run_action(Run, :commit_replay_pending, %{
      run_id: run_id,
      pending_calls: pending_calls,
      expected_memo_length: expected_memo_length
    })
  end

  @doc "Completes a run with the result of its final replay."
  def complete_replay(run_id, result_text, expected_memo_length) do
    Ankole.Ash.run_action(Run, :complete_replay, %{
      run_id: run_id,
      result_text: result_text,
      expected_memo_length: expected_memo_length
    })
  end

  @doc "Fails a run with the error of its final replay."
  def fail_replay(run_id, code, summary, expected_memo_length) do
    Ankole.Ash.run_action(Run, :fail_replay, %{
      run_id: run_id,
      code: code,
      summary: summary,
      expected_memo_length: expected_memo_length
    })
  end

  @doc """
  Requeues or fails the stale and overdue tasks of a run.

  A released task slot wakes the next capacity waiter after the commit. The
  caller does the terminal cleanup with `Lifecycle.cleanup_committed/1`.
  """
  def reconcile_stale_tasks(run_id, cutoff, reconciled_at) do
    Ankole.Ash.run_action(Run, :reconcile_stale_tasks, %{
      run_id: run_id,
      cutoff: cutoff,
      reconciled_at: reconciled_at
    })
  end

  @doc "Wakes the owner process of each run that still needs replay or cleanup."
  defdelegate reconcile_run_wakeups(), to: Ankole.Workflow.Recovery
end
