defmodule Ankole.Sessions.Main do
  @moduledoc "Owns admission for a user conversation."
  use Ankole.Sessions.RunType

  alias Ankole.Sessions.Commands
  alias Ankole.Conversations.ModelPreferences

  def instructions(run) do
    if optional_reply?(run.event),
      do:
        super(run) <>
          "\n\nYou are listening to a shared room. This message does not address you. Reply only when your contribution helps the discussion. You can finish with no visible reply.",
      else: super(run)
  end

  def repair(run, text), do: if(optional_reply?(run.event), do: nil, else: super(run, text))

  def finish(
        %{
          outcome: :loop_finished,
          model_response: %{content: content}
        } = run
      ) do
    text = Ankole.Conversations.Delivery.Text.visible_text(content) || ""

    if optional_reply?(run.event) and String.trim(text) == "" and not run.visible_delivery?,
      do: {:finalize, %{run | outcome: :silent}},
      else: super(run)
  end

  def finish(run), do: super(run)

  defp optional_reply?(%Ankole.Signals.Signal{
         producer: :kernel,
         type: "conversation.message.addressed",
         data: %{"optional_reply" => true}
       }),
       do: true

  defp optional_reply?(_event), do: false

  def plan(event, opts) do
    profile = Commands.profile(event) || ModelPreferences.for_event(event)

    opts =
      if profile,
        do: Keyword.put(opts, :profile, profile),
        else: opts

    if profile && profile != "primary" do
      case Ankole.AIGateway.ModelProfiles.get_custom_model_profile(
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
