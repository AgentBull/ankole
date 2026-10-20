defmodule Ankole.Sessions.Main do
  @moduledoc "Owns admission for a user conversation."
  use Ankole.Sessions.RunType

  alias Ankole.Sessions.Commands
  alias Ankole.Conversations.ModelPreferences

  def plan(event, opts) do
    profile = Commands.profile(event) || ModelPreferences.for_event(event)

    opts =
      if profile,
        do: Keyword.put(opts, :profile, profile),
        else: opts

    if profile && profile != "primary" do
      case Ankole.AIAgent.ModelProfiles.get_custom_model_profile(
             event.agent_uid,
             profile
           ) do
        {:ok, _} ->
          {:ok, %{kind: :main, opts: opts}}

        {:error, reason} ->
          {:error, {:model_profile_unavailable, profile, reason}}
      end
    else
      {:ok, %{kind: :main, opts: opts}}
    end
  end
end
