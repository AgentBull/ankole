defmodule Ankole.AIAgent.Library.Schemas.AgentSkillLesson.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIAgent.Library.Schemas.AgentSkillLesson`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_teach, input, context) do
    input.arguments
    |> Map.put(:author, Ankole.ActorRef.from_actor(context.actor))
    |> Ankole.AIAgent.Library.console_teach()
    |> Ankole.Errors.wrap(&Ankole.AIAgent.Library.SkillLessons.rejection/1)
  end

  defp action(:revoke, input, _context) do
    input.arguments
    |> Ankole.AIAgent.Library.SkillLessons.revoke()
    |> Ankole.Errors.wrap(&Ankole.AIAgent.Library.SkillLessons.rejection/1)
  end
end
