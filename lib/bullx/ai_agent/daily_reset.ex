defmodule BullX.AIAgent.DailyReset do
  @moduledoc """
  Profile-local Conversation reset helper.

  This closes stale active Conversations without deleting Messages or changing
  MailboxSession identity. Durable timestamps stay UTC while reset boundaries
  are evaluated in the profile's configured IANA time zone.
  """

  import Ecto.Query

  alias BullX.AIAgent.{Conversation, Conversations, Profile}
  alias BullX.AIAgent.Time, as: AgentTime
  alias BullX.Repo

  @spec close_eligible(Profile.t(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def close_eligible(%Profile{} = profile, now \\ DateTime.utc_now(:microsecond)) do
    close_eligible(profile, now, nil)
  end

  @spec close_eligible(Profile.t(), DateTime.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def close_eligible(%Profile{} = profile, now, agent_uid) do
    Conversation
    |> where([c], is_nil(c.ended_at))
    |> maybe_agent(agent_uid)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn conversation, {:ok, count} ->
      cond do
        not profile.daily_reset.enabled or not due_for_reset?(conversation, profile, now) ->
          {:cont, {:ok, count}}

        active_generation?(conversation, now) ->
          case schedule_retry(conversation, profile, now) do
            {:ok, _conversation} -> {:cont, {:ok, count}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        retry_pending?(conversation, now) ->
          {:cont, {:ok, count}}

        true ->
          case Conversations.close_active(conversation, "daily_reset", now) do
            {:ok, _conversation} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp maybe_agent(query, nil), do: query

  defp maybe_agent(query, agent_uid) when is_binary(agent_uid) do
    where(query, [c], c.agent_uid == ^agent_uid)
  end

  defp active_generation?(conversation, now) do
    Conversations.owned_active_lease?(
      conversation,
      conversation.generation["lease_id"] || "",
      now
    )
  end

  defp due_for_reset?(conversation, profile, now) do
    DateTime.compare(last_activity(conversation), reset_boundary(profile, now)) == :lt
  end

  defp retry_pending?(%Conversation{metadata: metadata}, now) do
    case metadata["daily_reset_retry_after"] do
      retry_after when is_binary(retry_after) ->
        case DateTime.from_iso8601(retry_after) do
          {:ok, datetime, _offset} -> DateTime.compare(datetime, now) == :gt
          _error -> false
        end

      _missing ->
        false
    end
  end

  defp schedule_retry(%Conversation{} = conversation, %Profile{} = profile, now) do
    retry_after =
      now
      |> DateTime.add(profile.daily_reset.retry_minutes, :minute)
      |> DateTime.to_iso8601()

    metadata = Map.put(conversation.metadata, "daily_reset_retry_after", retry_after)

    conversation
    |> Conversation.changeset(%{metadata: metadata})
    |> Repo.update()
  end

  defp last_activity(%Conversation{} = conversation) do
    BullX.AIAgent.Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> where([m], m.status == :complete)
    |> select([m], max(m.updated_at))
    |> Repo.one()
    |> case do
      nil -> conversation.updated_at
      datetime -> datetime
    end
  end

  defp reset_boundary(%Profile{} = profile, now) do
    [hour, minute] =
      profile.daily_reset.hour
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    timezone = profile.daily_reset.timezone
    wall_now = AgentTime.shift(now, timezone)
    today = DateTime.to_date(wall_now)
    boundary = wall_datetime(today, Time.new!(hour, minute, 0), timezone)

    case DateTime.compare(wall_now, boundary) do
      :lt -> DateTime.add(boundary, -86_400, :second)
      _other -> boundary
    end
  end

  defp wall_datetime(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
      {:error, _reason} -> DateTime.new!(date, time, "Etc/UTC")
    end
  end
end
