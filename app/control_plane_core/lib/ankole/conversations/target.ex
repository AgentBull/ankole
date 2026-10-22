defmodule Ankole.Conversations.Target do
  @moduledoc "A validated destination for an Agent statement."
  require Ash.Query
  alias Ankole.Conversations.Conversation
  alias Ankole.Sessions.Key

  @enforce_keys [:kind]
  defstruct [:conversation_id, :kind, :binding_name, :provider_thread_id, primary: true]

  def for_reply(_repo, event) do
    id = event.conversation_id

    case id && Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
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
    with {:ok, conversation} <-
           conversation_for_agent_in_tx(repo, agent_uid, Ankole.Attrs.get(item, :conversation_id)) do
      target = %__MODULE__{
        conversation_id: conversation.id,
        kind: conversation.kind,
        binding_name: Ankole.Attrs.get(item, :binding_name),
        provider_thread_id: Ankole.Attrs.get(item, :provider_thread_id),
        primary: Ankole.Attrs.get(item, :primary) != false
      }

      if valid_route?(target), do: {:ok, target}, else: {:error, :cron_delivery_route_required}
    else
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc "Resolves a conversation for an Agent that is one of its declared participants."
  def conversation_for_agent_in_tx(_repo, agent_uid, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Conversation{} = conversation <-
           Conversation
           |> Ash.Query.filter(
             id == ^id and
               exists(
                 Ankole.Conversations.Participant,
                 conversation_id == parent(id) and principal_uid == ^agent_uid and role == :agent
               )
           )
           |> Ankole.Ash.read_one!(),
         do: {:ok, conversation},
         else: (_ -> {:error, :conversation_not_found})
  end

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
end
