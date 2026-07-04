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
    - content does NOT contain function_call (only chain-tail rows)
    - no signal_entries with matching ai_message_id exists
    - updated_at is older than a grace period (60s) to avoid racing with live handlers
  """

  use GenServer, restart: :permanent

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIReplyPreview

  require Logger

  @scan_interval_ms 2 * 60 * 1_000
  @grace_period_seconds 60
  @batch_limit 25

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

    # Find terminal message rows with actor_event_id, no function_call in content,
    # and no matching signal_entries mirror.
    Message
    |> where([m], m.type == "message" and m.status == "complete")
    |> where([m], m.updated_at <= ^grace_cutoff)
    |> where([m], fragment("?->>'actor_event_id' IS NOT NULL", m.metadata))
    |> where(
      [m],
      # Exclude rows whose content contains function_call (intermediate rounds).
      fragment(
        "NOT EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS item WHERE item->>'type' = 'function_call')",
        m.content
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
      from a in ActorEvent,
        where: fragment("?->>'retry_of_actor_event_id'", a.payload) == ^event.id
    )
  end

  # Policy: determines whether a terminal message row should produce an
  # IM-visible reply. Shared by recovery scan and live preview handler.
  # Returns true if the row should be IM-visible, false to suppress.
  defp im_visible_policy(%Message{status: "complete"}, %ActorEvent{} = event) do
    # Only events with signal_channel_id are IM-visible.
    event.signal_channel_id != nil
  end

  defp im_visible_policy(%Message{}, _event), do: false

  # Performs the actual IM delivery for a recovered terminal message.
  defp recover_im_delivery(%ActorEvent{} = event, %Message{} = message) do
    # Extract visible text from the message content.
    text =
      (message.content || [])
      |> Enum.flat_map(&visible_text_parts/1)
      |> Enum.join("")
      |> String.trim()

    if text == "" do
      Logger.debug("RecoveryScan: message #{message.id} has no visible text, skipping")
      :ok
    else
      case AIReplyPreview.deliver_and_mirror_final_reply(event, message, text) do
        :ok ->
          Logger.info("RecoveryScan: recovered IM delivery for message #{message.id}")

        {:error, reason} ->
          Logger.warning(
            "RecoveryScan: failed to recover IM delivery for message #{message.id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp visible_text_parts(%{"type" => "message", "content" => content}) when is_list(content),
    do: Enum.flat_map(content, &visible_text_parts/1)

  defp visible_text_parts(%{"type" => type, "text" => text})
       when type in ["output_text", "text"] and is_binary(text),
       do: [text]

  defp visible_text_parts(%{"content" => text}) when is_binary(text), do: [text]
  defp visible_text_parts(_item), do: []

  # ─────────────────────────────────────────────────────────────────
  # Child spec
  # ─────────────────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
end
