defmodule Ankole.Sessions.SessionReset do
  @moduledoc false

  import Ankole.Sessions.Common, only: [collect_results: 1]

  alias Ankole.AIGateway
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Repo
  alias Ankole.SystemConfig
  alias Ankole.TimeZone

  @daily_reset_time ~T[04:30:00]

  @spec enqueue_daily_session_resets(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(opts \\ [])

  def enqueue_daily_session_resets(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, boundary_at, timezone} <- daily_reset_boundary_at(now, opts) do
      enqueue_daily_session_resets(boundary_at, Keyword.put(opts, :timezone, timezone))
    end
  end

  def enqueue_daily_session_resets(%DateTime{} = boundary_at) do
    enqueue_daily_session_resets(boundary_at, [])
  end

  @spec enqueue_daily_session_resets(DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(%DateTime{} = boundary_at, opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    timezone = Keyword.get(opts, :timezone, SystemConfig.default_timezone())

    Repo.transact(fn repo ->
      conversations = due_daily_reset_conversations(repo, boundary_at, opts)

      conversations
      |> Enum.map(&enqueue_session_reset_due_in_tx(repo, &1, boundary_at, now, opts))
      |> collect_results()
      |> case do
        {:ok, events} ->
          {:ok,
           %{
             status: :enqueued,
             boundary_at: boundary_at,
             timezone: timezone,
             due_sessions: length(conversations),
             signals: events
           }}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp daily_reset_boundary_at(%DateTime{} = now, opts) do
    with {:ok, timezone} <- daily_reset_timezone(opts),
         {:ok, reset_time} <- daily_reset_time(opts),
         {:ok, local_now} <- TimeZone.shift(now, timezone),
         date <- daily_reset_date(local_now, reset_time),
         {:ok, local_boundary} <- TimeZone.resolve_local(date, reset_time, timezone),
         {:ok, boundary_at} <- TimeZone.shift(local_boundary, "Etc/UTC") do
      {:ok, boundary_at, timezone}
    end
  end

  defp daily_reset_timezone(opts) do
    case Keyword.fetch(opts, :timezone) do
      {:ok, timezone} when is_binary(timezone) ->
        TimeZone.validate(timezone)

      {:ok, _timezone} ->
        {:error, :invalid_timezone}

      :error ->
        SystemConfig.timezone()
    end
  end

  defp daily_reset_time(opts) do
    opts
    |> Keyword.get(:reset_time, @daily_reset_time)
    |> normalize_reset_time()
  end

  defp normalize_reset_time(%Time{} = time), do: {:ok, Time.truncate(time, :second)}
  defp normalize_reset_time({hour, minute}), do: Time.new(hour, minute, 0)
  defp normalize_reset_time({hour, minute, second}), do: Time.new(hour, minute, second)
  defp normalize_reset_time(_value), do: {:error, :invalid_reset_time}

  defp daily_reset_date(%DateTime{} = local_now, %Time{} = reset_time) do
    date = DateTime.to_date(local_now)

    case Time.compare(DateTime.to_time(local_now), reset_time) do
      :lt -> Date.add(date, -1)
      _comparison -> date
    end
  end

  defp due_daily_reset_conversations(repo, %DateTime{} = boundary_at, opts) do
    ModelHistory.daily_reset_candidates_in_tx(repo, boundary_at, opts)
  end

  defp enqueue_session_reset_due_in_tx(
         repo,
         %{subject_uid: subject_uid, conversation_key: conversation_key} = conversation,
         %DateTime{} = boundary_at,
         %DateTime{} = now,
         opts
       ) do
    timezone = Keyword.get(opts, :timezone, SystemConfig.default_timezone())
    event_id = session_reset_due_event_id(conversation, boundary_at)

    with {:ok, reset_time} <- daily_reset_time(opts) do
      data = %{
        "session" => %{"agent_uid" => subject_uid, "session_id" => conversation_key},
        "reset" => %{
          "kind" => "daily",
          "boundary_at" => DateTime.to_iso8601(boundary_at),
          "timezone" => timezone,
          "local_time" => reset_time_label(reset_time)
        }
      }

      Ankole.Signals.accept_in_tx(repo, %{
        producer: :kernel,
        source: "control-plane://session-reset/daily",
        id: event_id,
        type: "session.reset_due",
        subject: "sessions:#{conversation_key}",
        time: now,
        data: data,
        target: %{agent_uid: subject_uid, session_id: conversation_key},
        authorization: Ankole.Principals.WorkAccess.service(),
        sender: nil
      })
    end
  end

  defp session_reset_due_event_id(
         %{subject_uid: subject_uid, conversation_key: conversation_key},
         %DateTime{} = boundary_at
       ) do
    "session.reset_due:daily:" <>
      subject_uid <>
      ":" <>
      conversation_key <>
      ":" <>
      DateTime.to_iso8601(boundary_at)
  end

  defp reset_time_label(%Time{} = reset_time) do
    reset_time
    |> Time.to_iso8601()
    |> String.replace_suffix(":00", "")
  end

  def process_due(session_key, %Signal{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with :ok <- Queue.lock_session_in_tx(repo, input.agent_uid, input.session_id),
           %Signal{} = input <- Ankole.Signals.lock_signal_in_tx(repo, input.id),
           {:ok, closed_conversation} <- close_current_session_for_reset(repo, session_key, now),
           {:ok, conversation} <-
             ensure_successor_conversation(repo, session_key, closed_conversation),
           {:ok, superseded_interactions} <-
             Interactions.supersede_for_session_reset_in_tx(repo, input, now),
           {:ok, completed_event} <-
             Queue.complete_session_lifecycle_event_in_tx(repo, input, completed_at: now) do
        {:ok,
         %{
           status: :session_reset,
           reset_event: input,
           closed_conversation: closed_conversation,
           conversation: conversation,
           superseded_reply_interactions: length(superseded_interactions),
           signal: completed_event
         }}
      else
        nil ->
          {:ok, %{status: :idle}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp close_current_session_for_reset(repo, session_key, now) do
    case AIGateway.active_conversation_for_update(
           repo,
           session_key.agent_uid,
           session_key.session_id
         ) do
      %{} ->
        with {:ok, conversation} <-
               ModelHistory.end_active_conversation_in_tx(
                 repo,
                 session_key.agent_uid,
                 session_key.session_id,
                 now
               ) do
          {:ok, conversation}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp ensure_successor_conversation(_repo, _session_key, nil), do: {:ok, nil}

  defp ensure_successor_conversation(repo, session_key, %{} = previous_conversation) do
    AIGateway.ensure_conversation_in_tx(
      repo,
      session_key.agent_uid,
      session_key.session_id,
      ModelHistory.successor_origin_metadata(previous_conversation)
    )
  end
end
