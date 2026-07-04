defmodule Ankole.SignalsGateway.RecoveryScan do
  @moduledoc """
  Bounded catch-up scan for terminal ai_gateway_messages whose final IM reply
  was not yet mirrored into signal_entries.

  Runs periodically (every 2 minutes) and at startup. Finds terminal message
  rows that should be IM-visible but lack a signal_entries mirror, and
  dispatches a best-effort final IM delivery.

  Scan criteria (plan §2.6):
    - type = "message"
    - status = "complete"
    - metadata.actor_event_id is present
    - actor event is IM-visible under the same predicate as AIReplyPreview
    - metadata.tool_result_journal is not true
    - content does NOT contain function_call (only chain-tail rows)
    - content contains visible final text
    - actor event has not been superseded by a retry event
    - no signal_entries with matching ai_message_id exists
    - updated_at is older than a grace period (60s) to avoid racing with live handlers
  """

  use GenServer, restart: :permanent

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.SignalEntry

  require Logger

  @scan_interval_ms 2 * 60 * 1_000
  @grace_period_seconds 60
  @batch_limit 25
  @silent_success_marker AIReplyText.silent_success_marker()
  @visible_text_exists_fragment """
  EXISTS (
    SELECT 1
    FROM jsonb_array_elements(?) AS item
    WHERE (
      item->>'type' IN ('output_text', 'text')
      AND btrim(item->>'text') <> ''
      AND btrim(item->>'text') <> '#{@silent_success_marker}'
    )
    OR (
      item->>'type' = 'message'
      AND COALESCE(item->>'role', 'assistant') = 'assistant'
      AND jsonb_typeof(item->'content') = 'array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(item->'content') AS part
        WHERE part->>'type' IN ('output_text', 'text')
          AND btrim(part->>'text') <> ''
          AND btrim(part->>'text') <> '#{@silent_success_marker}'
      )
    )
    OR (
      item->>'type' = 'message'
      AND COALESCE(item->>'role', 'assistant') = 'assistant'
      AND jsonb_typeof(item->'content') = 'string'
      AND btrim(item->>'content') <> ''
      AND btrim(item->>'content') <> '#{@silent_success_marker}'
    )
  )
  """

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Runs one scan cycle synchronously. Returns the number of rows processed.
  """
  @spec run_once() :: non_neg_integer()
  def run_once do
    messages = find_orphaned_terminals()
    Enum.each(messages, &recover_message/1)
    length(messages)
  end

  @doc """
  Finds terminal message rows that need IM delivery recovery.
  """
  @spec find_orphaned_terminals() :: [Message.t()]
  def find_orphaned_terminals do
    grace_cutoff = DateTime.utc_now(:microsecond) |> DateTime.add(-@grace_period_seconds, :second)
    im_visible_event_types = AIReplyPreview.im_visible_event_types()

    # Keep all durable eligibility predicates in SQL so skipped rows cannot
    # permanently occupy the bounded scan window.
    Message
    |> join(:inner, [m], e in ActorEvent,
      on: fragment("?->>'actor_event_id' = ?::text", m.metadata, e.id)
    )
    |> where([m, e], m.type == "message" and m.status == "complete")
    |> where([m], m.updated_at <= ^grace_cutoff)
    |> where([_m, e], not is_nil(e.signal_channel_id))
    |> where([_m, e], e.type in ^im_visible_event_types)
    |> where([m], fragment("?->>'tool_result_journal' IS DISTINCT FROM 'true'", m.metadata))
    |> where(
      [m],
      # Exclude rows whose content contains function_call (intermediate rounds).
      fragment(
        "NOT EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS item WHERE item->>'type' = 'function_call')",
        m.content
      )
    )
    |> where([m], fragment(@visible_text_exists_fragment, m.content))
    |> where(
      [_m, e],
      fragment(
        "NOT EXISTS (SELECT 1 FROM actor_events retry_event WHERE retry_event.id <> ? AND retry_event.payload #>> '{data,entry,retry_of_actor_event_id}' = ?::text)",
        e.id,
        e.id
      )
    )
    |> where(
      [m],
      # Exclude rows that already have a signal_entries mirror.
      fragment(
        "NOT EXISTS (SELECT 1 FROM signal_entries WHERE signal_entries.ai_message_id = ?)",
        m.id
      )
    )
    |> order_by([m], asc: m.updated_at)
    |> limit(@batch_limit)
    |> Repo.all()
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer (periodic sweep)
  # ─────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Run an initial scan shortly after startup, then periodically.
    Process.send_after(self(), :scan, 10_000)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    count = run_once()

    if count > 0 do
      Logger.info("RecoveryScan: processed #{count} orphaned terminal messages")
    end

    Process.send_after(self(), :scan, @scan_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ─────────────────────────────────────────────────────────────────
  # Recovery logic
  # ─────────────────────────────────────────────────────────────────

  defp recover_message(%Message{} = message) do
    actor_event_id = message.metadata["actor_event_id"]

    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        # Check retry suppression: if this event was superseded by a retry,
        # skip recovery to avoid duplicate IM replies.
        if retry_suppressed?(event) do
          Logger.debug(
            "RecoveryScan: skipping #{message.id} — event #{actor_event_id} was retried"
          )
        else
          # Policy check: should this terminal row be IM-visible?
          if im_visible_policy(message, event) do
            recover_im_delivery(event, message)
          end
        end

      nil ->
        Logger.warning(
          "RecoveryScan: actor event #{actor_event_id} not found for message #{message.id}"
        )
    end
  end

  # Checks if this event was superseded by a retry (the retry's event
  # references this event's id via retry_of_actor_event_id).
  defp retry_suppressed?(%ActorEvent{} = event) do
    # Look for any successor event that references this event as a retry source.
    Repo.exists?(
      from(a in ActorEvent,
        where: a.id != ^event.id,
        where: fragment("? #>> '{data,entry,retry_of_actor_event_id}'", a.payload) == ^event.id
      )
    )
  end

  # Policy: determines whether a terminal message row should produce an
  # IM-visible reply. The SQL scan applies the same predicate up front so
  # non-visible terminal rows cannot starve the bounded recovery window.
  defp im_visible_policy(%Message{status: "complete"}, %ActorEvent{} = event) do
    AIReplyPreview.im_visible_event?(event)
  end

  defp im_visible_policy(%Message{}, _event), do: false

  # Performs the actual IM delivery for a recovered terminal message. This is
  # intentionally best-effort: the singleton scanner and grace window avoid the
  # common live-finalize race, but provider send is never wrapped in a DB lock.
  defp recover_im_delivery(%ActorEvent{} = event, %Message{} = message) do
    with %Message{} = current_message <- fetch_recovery_message(message.id),
         false <- final_reply_mirrored?(Repo, current_message.id),
         :ok <- deliver_recovered_im_reply(event, current_message) do
      unless final_reply_mirrored?(Repo, current_message.id) do
        Logger.warning(
          "RecoveryScan: recovered IM delivery for message #{current_message.id} did not mirror a signal entry"
        )
      end

      :ok
    else
      nil ->
        :ok

      true ->
        :ok

      {:error, reason} = error ->
        defer_failed_recovery(message.id)

        Logger.warning(
          "RecoveryScan: failed to recover message #{message.id}: #{inspect(reason)}"
        )

        error
    end
  end

  defp defer_failed_recovery(message_id) when is_binary(message_id) do
    now = DateTime.utc_now(:microsecond)

    Message
    |> where([m], m.id == ^message_id)
    |> where([m], m.type == "message" and m.status == "complete")
    |> Repo.update_all(set: [updated_at: now])

    :ok
  end

  defp fetch_recovery_message(message_id) do
    Message
    |> where([m], m.id == ^message_id)
    |> where([m], m.type == "message" and m.status == "complete")
    |> where([m], fragment("?->>'actor_event_id' IS NOT NULL", m.metadata))
    |> where([m], fragment("?->>'tool_result_journal' IS DISTINCT FROM 'true'", m.metadata))
    |> where(
      [m],
      fragment(
        "NOT EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS item WHERE item->>'type' = 'function_call')",
        m.content
      )
    )
    |> where([m], fragment(@visible_text_exists_fragment, m.content))
    |> Repo.one()
  end

  defp final_reply_mirrored?(repo, message_id) do
    repo.exists?(
      from(entry in SignalEntry,
        where: entry.ai_message_id == ^message_id
      )
    )
  end

  defp deliver_recovered_im_reply(%ActorEvent{} = event, %Message{} = message) do
    case AIReplyText.visible_text(message.content || []) do
      nil ->
        Logger.debug("RecoveryScan: message #{message.id} has no visible text, skipping")
        :ok

      text ->
        case AIReplyPreview.deliver_and_mirror_final_reply(event, message, text) do
          :ok ->
            Logger.info("RecoveryScan: recovered IM delivery for message #{message.id}")
            :ok

          {:error, reason} ->
            Logger.warning(
              "RecoveryScan: failed to recover IM delivery for message #{message.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
end
