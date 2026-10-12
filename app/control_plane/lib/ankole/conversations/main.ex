defmodule Ankole.Conversations.Main do
  @moduledoc "Owns admission for a user conversation."
  use Ankole.Conversations.RunType

  alias Ankole.Conversations.Commands

  def plan(event, opts) do
    opts =
      if Commands.profile(event),
        do: Keyword.put(opts, :profile, Commands.profile(event)),
        else: opts

    if event.type == "command.llm" and Commands.profile(event) do
      case Ankole.AIAgent.ModelProfiles.get_custom_model_profile(
             event.agent_uid,
             Commands.profile(event)
           ) do
        {:ok, _} ->
          {:ok, %{kind: :main, opts: opts}}

        {:error, reason} ->
          {:error, {:model_profile_unavailable, Commands.profile(event), reason}}
      end
    else
      {:ok, %{kind: :main, opts: opts}}
    end
  end
end
