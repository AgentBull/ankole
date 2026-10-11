defmodule Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit do
  @moduledoc false

  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow

  @callback dead_letter_notice_text(ActorEvent.t()) :: String.t() | nil

  @work_units [Workflow, BackgroundAgentJobs]

  @spec dead_letter_notice_text(ActorEvent.t()) :: String.t() | nil
  def dead_letter_notice_text(%ActorEvent{} = event) do
    Enum.find_value(@work_units, & &1.dead_letter_notice_text(event))
  end
end
