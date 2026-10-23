defmodule Ankole.Sessions.Operations.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Sessions.Operations`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Repo

  alias Ankole.Sessions.{
    Admission,
    Ambient,
    AmbientCuration,
    AmbientTriage,
    CodexJob,
    Commands,
    MessageLifecycle,
    Notices,
    Presentation,
    Receipts,
    Revisions,
    Run,
    SessionReset,
    Worker,
    WorkflowTask
  }

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:admit_input, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Admission.admit_in_tx(Repo, args.key, args.snapshot, args.plan, args.prepared, args.now)
    )
  end

  defp action(:dead_letter_input, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Admission.dead_letter_input_in_tx(Repo, args.event, args.now, args.reason))
  end

  defp action(:authorize_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Admission.authorize_event_in_tx(Repo, args.event))

  defp action(:admit_job_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(CodexJob.admit_in_tx(Repo, args.admission, args.snapshot))

  defp action(:check_job_turn, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(CodexJob.check_turn_in_tx(Repo, args.run))

  defp action(:claim_job_mailbox, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(CodexJob.mailbox_in_tx(Repo, args.run))

  defp action(:abort_job_turn, %{arguments: args}, _context) do
    Ankole.Errors.wrap(CodexJob.abort_in_tx(Repo, args.ref, args.worker_id, args.error, args.now))
  end

  defp action(:reject_job_admission, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      CodexJob.reject_admission_in_tx(
        Repo,
        args.job,
        args.event,
        args.code,
        args.reason,
        args.now
      )
    )
  end

  defp action(:defer_run_retry, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.defer_retry_in_tx(Repo, args.run, args.error, args.now))

  defp action(:record_run_round, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.record_round_in_tx(Repo, args.run))

  defp action(:inject_run_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.inject_in_tx(Repo, args.run, args.events, args.now))

  defp action(:finalize_run, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Run.finalize_in_tx(Repo, args.run, args.outcome, args.reason, args.images))
  end

  defp action(:refund_run, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.refund_in_tx(Repo, args.run, args.mode))

  defp action(:check_run, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.check_live_in_tx(Repo, args.run, args.lock))

  defp action(:reclaim_run, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Run.reclaim_in_tx(Repo, args.run))

  defp action(:apply_command, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.apply_command_in_tx(Repo, args.key, args.event, args.now))

  defp action(:resolve_retry_action, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.retry_action_in_tx(Repo, args.run, args.event))

  defp action(:retry_current_turn, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.retry_current_in_tx(Repo, args.run, args.event, args.now))

  defp action(:post_stopped_notice, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Commands.post_stopped_notice_in_tx(Repo, args.event, args.command_type))
  end

  defp action(:submit_workflow_failure, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.workflow_failure_in_tx(Repo, args.run, args.failure))

  defp action(:compensate_workflow_error, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.workflow_error_in_tx(Repo, args.run, args.error))

  defp action(:consume_compress_command, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Commands.consume_compress_command_in_tx(Repo, args.input, args.compaction, args.now)
    )
  end

  defp action(:consume_command_feedback, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Commands.command_feedback_in_tx(Repo, args.input, args.text, args.now))

  defp action(:fail_workflow_model, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Notices.workflow_model_unavailable_in_tx(
        Repo,
        args.event,
        args.profile,
        args.reason,
        args.now
      )
    )
  end

  defp action(:reject_suspended_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Notices.reject_suspended_input_in_tx(Repo, args.event, args.now))

  defp action(:complete_without_turn, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Notices.complete_without_turn_in_tx(
        Repo,
        args.signal,
        args.status,
        args.fields,
        args.commit_notice
      )
    )
  end

  defp action(:apply_revision, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Revisions.apply_in_tx(Repo, args.run, args.event, args.now))

  defp action(:process_message_removal, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(MessageLifecycle.process_in_tx(Repo, args.input, args.now))

  defp action(:resolve_ambient, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ambient.resolve_in_tx(Repo, args.event, args.now))

  defp action(:retry_ambient_triage, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(AmbientTriage.retry_in_tx(Repo, args.key, args.event, args.now))

  defp action(:record_ambient_judgment, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      AmbientCuration.record_judgment_in_tx(
        Repo,
        args.key,
        args.signal_id,
        args.route,
        args.attrs
      )
    )
  end

  defp action(:set_standing_orders, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      AmbientCuration.set_standing_orders_in_tx(
        Repo,
        args.agent_uid,
        args.signal_id,
        args.orders,
        args.now
      )
    )
  end

  defp action(:execute_receipt, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Receipts.execute_in_tx(Repo, args.run, args.response_id, args.call_id, args.operation)
    )
  end

  defp action(:link_run_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Presentation.link_input_in_tx(Repo, args.run))

  defp action(:read_worker_status, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Worker.worker_status_in_tx(Repo, args.run))

  defp action(:enqueue_session_resets, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(SessionReset.enqueue_in_tx(Repo, args.boundary_at, args.opts))

  defp action(:reset_session, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      SessionReset.process_due_in_tx(Repo, args.session_key, args.input, args.now)
    )
  end

  defp action(:close_workflow_input, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(WorkflowTask.complete_input_in_tx(Repo, args.event, args.now))
end
