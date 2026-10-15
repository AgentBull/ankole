defmodule Ankole.Sessions.Run.Notifications do
  @moduledoc "Publishes committed Session results and closes their live presentation."
  alias Ankole.Sessions.Presentation
  alias Ankole.AIGateway.ToolResultJournal

  def after_finalization(result) do
    publish_native_result(result)

    case result do
      {:ok, %{run: run} = result} ->
        if result.journal,
          do: ToolResultJournal.publish_tool_result_events(result.journal.message)

        Presentation.stop(run)
        {:ok, result}

      other ->
        other
    end
  end

  defp publish_native_result({:ok, %Ankole.Sessions.Run{event: event}}),
    do: Ankole.Conversations.publish_status(event)

  defp publish_native_result({:ok, %{signal: event} = result}) do
    Enum.each(
      Map.get(result, :posted, %Ankole.Conversations.PostResult{}).messages,
      &Ankole.Conversations.publish_statement/1
    )

    Ankole.Conversations.publish_status(event)
  end

  defp publish_native_result(_result), do: :ok

  def after_injection(result) do
    case result do
      {:ok, {events, completed}} ->
        Enum.each(completed, &after_finalization({:ok, &1}))
        Enum.each(events, &Ankole.Conversations.publish_status/1)
        {:ok, events}

      error ->
        error
    end
  end
end
