defmodule Ankole.BackgroundAgentJobs.Changes.TransitionToArgument do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do:
      AshStateMachine.transition_state(
        changeset,
        Ash.Changeset.get_argument(changeset, :next_status)
      )
end
