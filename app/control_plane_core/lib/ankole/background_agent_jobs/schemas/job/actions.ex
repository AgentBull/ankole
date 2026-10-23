defmodule Ankole.BackgroundAgentJobs.Schemas.Job.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.BackgroundAgentJobs.Schemas.Job`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:start, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(
        Ankole.Repo,
        input.arguments.attrs
      )
    )
  end

  defp action(:respawn, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Dispatch.respawn_with_dispatch_in_tx(
        Ankole.Repo,
        input.arguments.source_job_id,
        input.arguments.attrs
      )
    )
  end

  defp action(:request_stop, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.request_stop_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.attrs
      )
    )
  end

  defp action(:console_cancel, input, context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.console_cancel_in_tx(
        Ankole.Repo,
        input.arguments.id,
        context.actor
      ),
      &Ankole.BackgroundAgentJobs.Control.console_rejection/1
    )
  end

  defp action(:console_complete, input, context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.console_complete_in_tx(
        Ankole.Repo,
        input.arguments.id,
        input.arguments.result_summary,
        context.actor
      ),
      &Ankole.BackgroundAgentJobs.Control.console_rejection/1
    )
  end

  defp action(:request_complete, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.request_complete_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.attrs
      )
    )
  end

  defp action(:send_message, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.send_message_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.attrs
      )
    )
  end

  defp action(:commit_status, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Lifecycle.commit_status_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.agent_uid,
        input.arguments.attrs,
        input.arguments.options
      )
    )
  end

  defp action(:complete_signal, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Dispatch.complete_signal_in_tx(
        Ankole.Repo,
        input.arguments.signal
      )
    )
  end

  defp action(:resolve_worker_timeout, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.WorkerWait.resolve_timeout_in_tx(
        Ankole.Repo,
        input.arguments.signal,
        input.arguments.job,
        input.arguments.now
      )
    )
  end

  defp action(:inspect_stall, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.TurnWatchdog.inspect_stall_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.now
      )
    )
  end
end
