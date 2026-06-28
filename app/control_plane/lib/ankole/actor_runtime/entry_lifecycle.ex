defmodule Ankole.ActorRuntime.EntryLifecycle do
  @moduledoc false

  import Ankole.ActorRuntime.Common

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.Repo
  alias Ankole.Schedule

  def process(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- TurnLifecycle.lock_actor_input(repo, input.id),
           {:ok, conversation} <-
             AIAgent.ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
           %Conversation{} = conversation <- AIAgent.lock_conversation(repo, conversation.id),
           {:ok, message} <- insert_entry_lifecycle_introspection(repo, conversation, input, now),
           {:ok, cancelled_checkbacks} <-
             Schedule.cancel_checkbacks_for_provider_entry_in_tx(
               repo,
               %{
                 "agent_uid" => input.agent_uid,
                 "session_id" => input.session_id,
                 "binding_name" => input.binding_name,
                 "provider_entry_id" => input.provider_entry_id
               },
               now
             ),
           {:ok, consumption} <-
             Actors.consume_entry_lifecycle_input_in_tx(repo, input,
               conversation_id: conversation.id,
               consumed_at: now
             ) do
        {:ok,
         %{
           status: :entry_lifecycle_recorded,
           lifecycle_input: input,
           conversation: conversation,
           message: message,
           cancelled_checkbacks: cancelled_checkbacks,
           consumption: consumption
         }}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp insert_entry_lifecycle_introspection(
         repo,
         %Conversation{} = conversation,
         %ActorInput{} = input,
         now
       ) do
    lifecycle_kind = "removed"

    %Message{}
    |> Message.changeset(%{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "user",
      kind: "introspection",
      status: "complete",
      content: [%{"type" => "text", "text" => entry_lifecycle_note(input, lifecycle_kind)}],
      event_source: "signals_gateway:#{input.binding_name}",
      event_id: input.ingress_event_id,
      metadata: entry_lifecycle_metadata(input, lifecycle_kind, now)
    })
    |> repo.insert()
  end

  defp entry_lifecycle_note(%ActorInput{} = input, lifecycle_kind) do
    "The provider reported that a previously visible user entry was #{lifecycle_kind}. " <>
      "Preserve the existing conversation history; use this only as lifecycle context for future reasoning. " <>
      "provider_entry_id=#{input.provider_entry_id || "unknown"}; signal_channel_id=#{input.signal_channel_id || "unknown"}."
  end

  defp entry_lifecycle_metadata(%ActorInput{} = input, lifecycle_kind, now) do
    %{
      "actor_input_id" => input.id,
      "actor_input_type" => input.type,
      "binding_name" => input.binding_name,
      "session_id" => input.session_id,
      "signal_channel_id" => input.signal_channel_id,
      "provider_thread_id" => input.provider_thread_id,
      "provider_entry_id" => input.provider_entry_id,
      "provider_refs" =>
        reject_nil_values(%{
          "event_id" => input.ingress_event_id,
          "provider_message_id" => input.provider_entry_id,
          "room_id" => input.signal_channel_id,
          "thread_id" => input.provider_thread_id || input.signal_channel_id
        }),
      "lifecycle" =>
        %{
          "kind" => lifecycle_kind,
          "provider_kind" => entry_lifecycle_provider_kind(input),
          "source" => "signals_gateway",
          "inserted_at" => DateTime.to_iso8601(now)
        }
        |> reject_nil_values()
    }
    |> reject_nil_values()
  end

  defp entry_lifecycle_provider_kind(%ActorInput{} = input) do
    case get_in(input.payload || %{}, ["data", "lifecycle", "provider_kind"]) do
      kind when is_binary(kind) and kind != "" -> kind
      _other -> nil
    end
  end
end
