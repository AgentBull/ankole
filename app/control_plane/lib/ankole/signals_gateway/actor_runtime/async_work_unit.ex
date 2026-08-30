defmodule Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit do
  @moduledoc false

  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow

  @callback dead_letter_after_turn_error?(ActorEvent.t(), map(), boolean()) :: boolean()
  @callback turn_error_retry_at(map(), pos_integer(), DateTime.t()) :: DateTime.t()
  @callback dead_letter_notice_text(ActorEvent.t()) :: String.t() | nil
  @callback compensate_turn_error_in_tx(module(), ActorEvent.t(), map(), DateTime.t()) ::
              {:ok, term()} | {:error, term()}

  @work_units [Workflow, BackgroundAgentJobs]

  @spec for_session(term()) :: module() | nil
  def for_session(session_id) do
    case Workflow.parse_task_session_id(session_id) do
      {:ok, _call_id} ->
        Workflow

      :error ->
        case BackgroundAgentJobs.parse_job_session_id(session_id) do
          {:ok, _job_id} -> BackgroundAgentJobs
          :error -> nil
        end
    end
  end

  @spec dead_letter_notice_text(ActorEvent.t()) :: String.t() | nil
  def dead_letter_notice_text(%ActorEvent{} = event) do
    Enum.find_value(@work_units, & &1.dead_letter_notice_text(event))
  end
end
