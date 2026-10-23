defmodule Ankole.BackgroundAgentJobs.Schemas.Job.Preparations do
  @moduledoc """
  Runs the preparations of `Ankole.BackgroundAgentJobs.Schemas.Job` that call
  domain code.
  """
  use Ash.Resource.Preparation

  alias Ankole.BackgroundAgentJobs.Queries

  @impl true
  def prepare(query, _opts, context), do: action(query.action.name, query, context)

  defp action(:console_list, query, _context), do: Queries.prepare_console_list(query)
  defp action(:list_for_agent, query, _context), do: Queries.prepare_agent_list(query)
end
