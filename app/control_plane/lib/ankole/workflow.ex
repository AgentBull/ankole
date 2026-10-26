defmodule Ankole.Workflow do
  @moduledoc """
  The Workflow domain: durable program runs and their Agent calls.

  This module declares cross-domain interfaces. RunServer calls the replay
  and recovery owner modules directly. Each top-level write owns its transaction
  and post-commit work. Code that already runs in a transaction composes the
  `_in_tx` functions of the owner modules
  (`Ankole.Workflow.TaskLifecycle`, `Ankole.Workflow.Lifecycle`, and
  `Ankole.Workflow.Slot`) and calls `cleanup_terminal_transition/1` after its
  commit.

  An operation gives `{:ok, value}` or `{:error, reason}`, where `reason` is the
  domain reason or an `Ash.Error.Invalid` error for invalid attributes.
  """
  use Ankole.Ash.Domain

  @behaviour Ankole.Sessions.AsyncWorkUnit

  alias Ankole.Repo
  alias Ankole.Workflow.Lifecycle
  alias Ankole.Workflow.Mail
  alias Ankole.Workflow.Queries
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  resources do
    resource Run do
      define(:get_run, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_runs, action: :read)
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
    do: Repo.transact_top_level(fn -> Lifecycle.create_with_dispatch_in_tx(attrs) end)

  @doc "Sends an owner message to one live task of a run."
  def send_task_message(run_id, call_seq, agent_uid, message, source_tool_call_id) do
    Repo.transact_top_level(fn ->
      Mail.send_task_message_in_tx(run_id, call_seq, agent_uid, message, source_tool_call_id)
    end)
  end

  @doc "Defers a task Signal until the Agent has free Workflow capacity."
  def defer_task_event(signal, available_at, reason) do
    Repo.transact_top_level(fn ->
      Mail.defer_task_event_in_tx(signal, available_at, reason)
    end)
  end

  @doc "Wakes the owner process of each run that still needs replay or cleanup."
  defdelegate reconcile_run_wakeups(), to: Ankole.Workflow.Recovery
end
