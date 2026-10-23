defmodule Ankole.Workflow.Schemas.AgentCall.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Workflow.Schemas.AgentCall`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:send_task_message, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Mail.send_task_message_in_tx(
      args.run_id,
      args.call_seq,
      args.agent_uid,
      args.message,
      args.source_tool_call_id
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:defer_task_event, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Mail.defer_task_event_in_tx(
      args.signal,
      args.available_at,
      args.reason
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:release_capacity, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Mail.release_capacity_in_tx(args.agent_uid)
    |> Ankole.Errors.wrap()
  end
end
