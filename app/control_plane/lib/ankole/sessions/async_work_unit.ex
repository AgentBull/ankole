defmodule Ankole.Sessions.AsyncWorkUnit do
  @moduledoc false

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Signals.Signal
  alias Ankole.Workflow

  @callback dead_letter_notice_text(Signal.t()) :: String.t() | nil

  @work_units [Workflow, BackgroundAgentJobs]

  @spec dead_letter_notice_text(Signal.t()) :: String.t() | nil
  def dead_letter_notice_text(%Signal{} = event) do
    Enum.find_value(@work_units, & &1.dead_letter_notice_text(event))
  end
end
