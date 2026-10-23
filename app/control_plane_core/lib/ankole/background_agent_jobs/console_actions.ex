defmodule Ankole.BackgroundAgentJobs.ConsoleActions do
  @moduledoc "Reads Job reliability and bounded runtime Turn pages."
  use Ash.Resource.Actions.Implementation
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Errors
  @impl true
  def run(input, _opts, _context), do: input |> execute() |> Errors.wrap(&describe/1)

  defp execute(%{action: %{name: :console_health}}),
    do: {:ok, BackgroundAgentJobs.health_metrics()}

  defp execute(%{action: %{name: :console_turns}, arguments: attrs}) do
    with %Job{} = job <- BackgroundAgentJobs.get_job(attrs.job_id),
         {:ok, page} <- BackgroundAgentJobs.console_turn_page(job, Map.get(attrs, :cursor)) do
      {:ok, %{turns: page.turns, next_cursor: page.next_cursor}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp describe(:not_found), do: Errors.Invalid.NotFound.exception(resource: Job)
  defp describe(_), do: {"The Job or Turn cursor is invalid", []}
end
