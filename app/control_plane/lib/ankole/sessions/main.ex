defmodule Ankole.Sessions.Main do
  @moduledoc "Owns admission for a user conversation."
  use Ankole.Sessions.RunType

  alias Ankole.Sessions.Commands
  alias Ankole.Conversations.ModelPreferences

  # Every turn of a conversation shares one prompt-cache key, so the
  # instructions carry only facts about the conversation itself. Guidance for
  # one kind of event travels with that turn's input instead.
  # The note sits directly above the event it describes, after any standing
  # orders that precede that event.
  def input(run) do
    case turn_note(run) do
      nil -> super(run)
      note -> List.insert_at(super(run), -2, Ankole.Sessions.Run.user(note))
    end
  end

  defp turn_note(run) do
    cond do
      Ankole.Sessions.Prompt.peer_exchange?(run.context.conversation) ->
        nil

      run.event.type == "agent.peer_message" and Map.get(run.event.data, "peer_hop_count", 0) >= 6 ->
        "This delegation chain has reached its six-hop limit. Report the current result and any unresolved decision to the human here. Do not start another delegation until the human provides a new instruction."

      run.event.type == "agent.peer_message" ->
        "An AI colleague has returned the result below. Integrate it into a useful conclusion for the human in this conversation, preserving canonical page links. You may finish silently if it is only an acknowledgment or adds no useful information."

      optional_reply?(run) ->
        "You are listening to a shared room. The message below does not address you. Reply only when your contribution helps the discussion; you can finish with no visible reply unless a later message addresses you."

      true ->
        nil
    end
  end

  def repair(run, text), do: if(optional_reply?(run), do: nil, else: super(run, text))

  def finish(
        %{
          outcome: :loop_finished,
          model_response: %{content: content}
        } = run
      ) do
    text = Ankole.Conversations.Delivery.Text.visible_text(content) || ""

    if optional_reply?(run) and String.trim(text) == "" and not run.visible_delivery?,
      do: {:finalize, %{run | outcome: :silent}},
      else: super(run)
  end

  def finish(run), do: super(run)

  defp optional_reply?(run) do
    optional_input?(run.event) and
      Enum.all?(run.steer_event_ids, &optional_input?(Ankole.Signals.get_signal!(&1)))
  end

  defp optional_input?(%Ankole.Signals.Signal{
         producer: :kernel,
         type: "conversation.message.addressed",
         data: %{"optional_reply" => true}
       }),
       do: true

  defp optional_input?(%{
         producer: :kernel,
         type: "agent.peer_message",
         data: %{"peer_hop_count" => hops}
       })
       when hops >= 6, do: false

  defp optional_input?(%{producer: :kernel, type: "agent.peer_message"}), do: true

  defp optional_input?(_event), do: false

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
