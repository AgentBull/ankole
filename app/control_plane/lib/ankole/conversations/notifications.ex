defmodule Ankole.Conversations.Notifications do
  @moduledoc """
  Chooses the Humans whom Ankole notifies about a native room's newest notifiable message.

  A Human receives the notification when the room still shows that message as
  unread to them: they did not write it, their read position is behind it, they
  can still see the room, and they have not muted it. A message that asks for a
  decision (a Clarify question, an Action Card, a connector authorization, or a
  Page access request) reaches muted rooms as well.
  Each claim advances the Human's `notified_seq`, so a message notifies each
  Human at most once however many times the caller runs.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations.{Conversation, Message, NativeRoom, Participant}

  @type claim :: %{
          conversation: Conversation.t(),
          message: Message.t(),
          decision?: boolean(),
          recipients: [String.t()]
        }

  @doc """
  Claims the room's newest notifiable message for the Humans it notifies.

  With `settled_before:`, a message that committed after that time is not
  claimed yet and the result says how many seconds to wait, so a Human who is
  reading the room has time to mark it read.
  """
  @spec claim(Ecto.UUID.t(), keyword()) :: {:ok, claim()} | {:wait, pos_integer()} | :none
  def claim(id, opts \\ []) do
    Ankole.Repo.assert_outside_transaction!()

    with %Conversation{kind: :native, last_notifiable_seq: seq} = conversation when seq > 0 <-
           Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         %Message{} = message <-
           Message
           |> Ash.Query.filter(conversation_id == ^id and seq == ^seq and not withdrawn)
           |> Ankole.Ash.read_one!(),
         :settled <- settled(message, opts[:settled_before]) do
      decision? = decision?(message)

      # Every Human behind the message is claimed, including those it does not notify, so a
      # later delivery never pushes an older message to someone who unmutes or rejoins.
      {:ok, claimed} =
        Participant
        |> Ash.Query.filter(conversation_id == ^id and role != :agent and notified_seq < ^seq)
        |> Ankole.Ash.update_where(:claim_notification, %{seq: seq})

      recipients =
        claimed
        |> Enum.filter(
          &(&1.principal_uid != message.author_uid and &1.last_read_seq < seq and
              (decision? or not &1.muted))
        )
        |> Enum.map(& &1.principal_uid)
        |> Enum.filter(&visible?(&1, id))

      {:ok,
       %{
         conversation: conversation,
         message: message,
         decision?: decision?,
         recipients: recipients
       }}
    else
      {:wait, seconds} -> {:wait, seconds}
      _ -> :none
    end
  end

  @spec decision?(Message.t()) :: boolean()
  def decision?(%Message{rich_content: rich}) when is_map(rich),
    do: Enum.any?(~w(clarify action_card connector_auth access_blocked), &is_map(rich[&1]))

  def decision?(_message), do: false

  defp settled(_message, nil), do: :settled

  defp settled(message, settled_before) do
    case DateTime.diff(message.created_at, settled_before, :millisecond) do
      wait when wait > 0 -> {:wait, div(wait, 1000) + 1}
      _ -> :settled
    end
  end

  defp visible?(uid, id) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, principal} ->
        not is_nil(NativeRoom.visible(Actor.new(principal), id, current_principal: principal))

      _ ->
        false
    end
  end
end
