defmodule Ankole.BackgroundAgentJobs.TurnState do
  @moduledoc """
  Kinds and statuses exposed by the background Agent Job Turn resource.
  """

  alias Ankole.BackgroundAgentJobs.Schemas.Turn

  @type status :: Turn.status()

  @spec kinds() :: [String.t()]
  defdelegate kinds(), to: Turn

  @spec statuses() :: [status()]
  def statuses,
    do: AshStateMachine.Info.state_machine_all_states(Turn)
end
