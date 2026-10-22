defmodule Ankole.BackgroundAgentJobs.Changes.TransitionToArgument do
  @moduledoc """
  Moves a resource to the state in its `next_status` argument.

  The state machine of the resource decides if the transition is permitted.
  When the argument is missing, the change adds the declared rejection that the
  `missing:` option names.
  """
  use Ash.Resource.Change

  alias Ankole.Errors.Invalid.Rejected

  @impl true
  def change(changeset, opts, _context) do
    case Ash.Changeset.get_argument(changeset, :next_status) do
      nil ->
        Ash.Changeset.add_error(
          changeset,
          Rejected.exception(reason: Keyword.fetch!(opts, :missing))
        )

      status ->
        AshStateMachine.transition_state(changeset, status)
    end
  end
end
