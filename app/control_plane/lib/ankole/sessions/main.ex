defmodule Ankole.Sessions.Main do
  @moduledoc "Owns admission for a user conversation."
  use Ankole.Sessions.RunType

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.Sessions.Commands

  def tools(run, tools, hosted) do
    {tools, hosted} = super(run, tools, hosted)

    attachments? =
      case StatementTarget.for_reply(Ankole.Repo, run.event) do
        {:ok, target} -> StatementTarget.accepts_attachments?(target)
        _ -> true
      end

    if not attachments? do
      {Enum.reject(tools, &(&1["name"] == "reply_attachment")),
       Enum.reject(hosted, &(&1["type"] == "image_generation"))}
    else
      {tools, hosted}
    end
  end

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
