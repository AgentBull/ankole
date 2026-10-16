defmodule Ankole.Conversations.Target do
  @moduledoc "A validated destination for an Agent statement."
  import Ecto.Query
  alias Ankole.Conversations.{Conversation, Participant}
  alias Ankole.Sessions.Key

  @enforce_keys [:kind]
  defstruct [:conversation_id, :kind, :binding_name, :provider_thread_id, primary: true]

  def for_reply(repo, event) do
    id = event.conversation_id

    case id && repo.get_by(Conversation, id: id) do
      %Conversation{kind: :native} ->
        if Key.parse(event.session_id) == {:conversation, id},
          do: {:ok, %__MODULE__{kind: :native, conversation_id: id}},
          else: {:error, :reply_route_unavailable}

      %Conversation{kind: :external} ->
        if is_binary(event.reply_binding_name) and event.reply_binding_name != "",
          do:
            {:ok,
             %__MODULE__{
               kind: :external,
               conversation_id: id,
               binding_name: event.reply_binding_name,
               provider_thread_id: event.provider_thread_id
             }},
          else: {:error, :reply_route_unavailable}

      _ ->
        {:error, :reply_route_unavailable}
    end
  end

  def for_delivery_in_tx(repo, agent_uid, item) do
    with {:ok, id} <- Ecto.UUID.cast(value(item, :conversation_id)),
         %Conversation{} = conversation <- repo.get_by(Conversation, id: id),
         true <-
           repo.exists?(
             from(p in Participant,
               where:
                 p.conversation_id == ^id and p.principal_uid == ^agent_uid and p.role == :agent
             )
           ) do
      target = %__MODULE__{
        conversation_id: id,
        kind: conversation.kind,
        binding_name: value(item, :binding_name),
        provider_thread_id: value(item, :provider_thread_id),
        primary: value(item, :primary) != false
      }

      if valid_route?(target), do: {:ok, target}, else: {:error, :cron_delivery_route_required}
    else
      _ -> {:error, :conversation_not_found}
    end
  end

  def accepts_attachments?(%__MODULE__{kind: :native}), do: false
  def accepts_attachments?(%__MODULE__{kind: :external}), do: true

  def reply_eligible?(%__MODULE__{kind: :native}, _event), do: true

  def reply_eligible?(%__MODULE__{kind: :external} = target, event) do
    is_binary(target.conversation_id) and valid_route?(target) and
      event.type in Ankole.Conversations.Delivery.Preview.channel_reply_event_types()
  end

  defp valid_route?(%__MODULE__{kind: :native, binding_name: nil, provider_thread_id: nil}),
    do: true

  defp valid_route?(%__MODULE__{kind: :external, binding_name: binding}),
    do: is_binary(binding) and String.trim(binding) != ""

  defp valid_route?(_target), do: false
  defp value(item, key), do: Map.get(item, key, Map.get(item, Atom.to_string(key)))
end
