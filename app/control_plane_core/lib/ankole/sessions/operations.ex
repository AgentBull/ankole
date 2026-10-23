defmodule Ankole.Sessions.Operations do
  @moduledoc """
  Declares the Session operations of `Ankole.Sessions.SessionWorkspace`.

  Each operation is a generic action that owns one transaction. Its `run`
  calls the `*_in_tx` function of the owning module with `Ankole.Repo`. The
  `Ankole.Sessions` domain defines one function for each operation; the
  modules call the define and give back the domain reason with
  `Ankole.Errors.reason/1`.
  """
  use Spark.Dsl.Fragment, of: Ash.Resource

  import Ankole.Ash.Resource, only: [after_commit: 1]

  alias Ankole.Sessions.{
    Receipts,
    Run
  }

  actions do
    action :admit_input, :term do
      description("Admits one input: claims the Session epoch and starts its attempt.")
      argument(:key, :term)
      argument(:snapshot, :term)
      argument(:plan, :term)
      argument(:prepared, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :dead_letter_input, :term do
      description("Dead-letters one input.")
      argument(:event, :term)
      argument(:now, :term)
      argument(:reason, :term)

      run(__MODULE__.Actions)
    end

    action :authorize_input, :term do
      description("Checks the work authorization of one input.")
      argument(:event, :term)

      run(__MODULE__.Actions)
    end

    action :admit_job_input, :term do
      description("Admits or adopts one background Job attempt.")
      argument(:admission, :term)
      argument(:snapshot, :term)

      run(__MODULE__.Actions)
    end

    action :check_job_turn, :term do
      description("Checks that a Job turn may start on its Worker.")
      argument(:run, :term)

      run(__MODULE__.Actions)
    end

    action :claim_job_mailbox, :term do
      description("Claims the steer input of a running Job turn.")
      argument(:run, :term)

      run(__MODULE__.Actions)
    end

    action :abort_job_turn, :term do
      description("Records a Job turn that its Worker aborted.")
      argument(:ref, :term)
      argument(:worker_id, :term)
      argument(:error, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :reject_job_admission, :term do
      description("Fails a Job that admission rejected and dead-letters its input.")
      argument(:job, :term)
      argument(:event, :term)
      argument(:code, :term)
      argument(:reason, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :defer_run_retry, :term do
      description("Defers the input of a failed run to its retry time.")
      argument(:run, :term)
      argument(:error, :term)
      argument(:now, :term)
      after_commit({Run, :publish_retry})

      run(__MODULE__.Actions)
    end

    action :record_run_round, :term do
      description("Records the tool results of one model round.")
      argument(:run, :term)
      after_commit({Run, :publish_journal})

      run(__MODULE__.Actions)
    end

    action :inject_run_input, :term do
      description("Starts pending input inside a running turn.")
      argument(:run, :term)
      argument(:events, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :finalize_run, :term do
      description("Closes a run with its terminal outcome and visible statement.")
      argument(:run, :term)
      argument(:outcome, :term)
      argument(:reason, :term)
      argument(:images, :term)

      run(__MODULE__.Actions)
    end

    action :refund_run, :term do
      description("Gives back the attempt of a run that did not finish.")
      argument(:run, :term)
      argument(:mode, :term)

      run(__MODULE__.Actions)
    end

    action :check_run, :term do
      description("Checks the epoch fence of a run.")
      argument(:run, :term)
      argument(:lock, :term)

      run(__MODULE__.Actions)
    end

    action :reclaim_run, :term do
      description("Fails the model responses that a previous Driver left generating.")
      argument(:run, :term)
      after_commit({Run, :publish_reclaimed})

      run(__MODULE__.Actions)
    end

    action :apply_command, :term do
      description("Applies one conversation command.")
      argument(:key, :term)
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :resolve_retry_action, :term do
      description("Decides whether a targeted retry interrupts the current run.")
      argument(:run, :term)
      argument(:event, :term)

      run(__MODULE__.Actions)
    end

    action :retry_current_turn, :term do
      description("Retries the current turn.")
      argument(:run, :term)
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :post_stopped_notice, :term do
      description("Posts the stopped state on a provider preview card.")
      argument(:event, :term)
      argument(:command_type, :term)

      run(__MODULE__.Actions)
    end

    action :submit_workflow_failure, :term do
      description("Submits the failure of a Workflow task run.")
      argument(:run, :term)
      argument(:failure, :term)

      run(__MODULE__.Actions)
    end

    action :compensate_workflow_error, :term do
      description("Compensates a turn error of a Workflow task run.")
      argument(:run, :term)
      argument(:error, :term)

      run(__MODULE__.Actions)
    end

    action :consume_compress_command, :term do
      description("Completes a compress command with its feedback.")
      argument(:input, :term)
      argument(:compaction, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :consume_command_feedback, :term do
      description("Completes a command with its feedback text.")
      argument(:input, :term)
      argument(:text, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :fail_workflow_model, :term do
      description("Fails a Workflow task whose model profile is unavailable.")
      argument(:event, :term)
      argument(:profile, :term)
      argument(:reason, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :reject_suspended_input, :term do
      description("Closes new input of a suspended tenant with a notice.")
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :complete_without_turn, :term do
      description("Closes input that cannot start a turn, with an optional notice.")
      argument(:signal, :term)
      argument(:status, :term)
      argument(:fields, :term)
      argument(:commit_notice, :term)

      run(__MODULE__.Actions)
    end

    action :apply_revision, :term do
      description("Applies an input revision to the current run.")
      argument(:run, :term)
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :process_message_removal, :term do
      description("Applies the removal of a provider message to its Session.")
      argument(:input, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :resolve_ambient, :term do
      description("Resolves whether ambient input is still fresh.")
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :retry_ambient_triage, :term do
      description("Defers ambient input after a failed classification.")
      argument(:key, :term)
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :record_ambient_judgment, :term do
      description("Records the ambient judgment of one input.")
      argument(:key, :term)
      argument(:signal_id, :term)
      argument(:route, :term)
      argument(:attrs, :term)

      run(__MODULE__.Actions)
    end

    action :set_standing_orders, :term do
      description("Replaces the standing orders of the conversation of one input.")
      argument(:agent_uid, :term)
      argument(:signal_id, :term)
      argument(:orders, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :execute_receipt, :term do
      description("Commits one control-plane tool result with its domain write.")
      argument(:run, :term)
      argument(:response_id, :term)
      argument(:call_id, :term)
      argument(:operation, :term)
      after_commit({Receipts, :publish_committed})

      run(__MODULE__.Actions)
    end

    action :link_run_input, :term do
      description("Links the attachments of the run input to the conversation.")
      argument(:run, :term)

      run(__MODULE__.Actions)
    end

    action :read_worker_status, :term do
      description("Reads the Worker workspace status under the epoch fence.")
      argument(:run, :term)

      run(__MODULE__.Actions)
    end

    action :enqueue_session_resets, :term do
      description("Queues the daily reset of the due Sessions.")
      argument(:boundary_at, :term)
      argument(:opts, :term)

      run(__MODULE__.Actions)
    end

    action :reset_session, :term do
      description("Resets one Session and starts its successor conversation.")
      argument(:session_key, :term)
      argument(:input, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end

    action :close_workflow_input, :term do
      description("Closes the input of a finished Workflow task.")
      argument(:event, :term)
      argument(:now, :term)

      run(__MODULE__.Actions)
    end
  end
end
