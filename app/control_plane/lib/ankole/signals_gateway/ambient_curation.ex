defmodule Ankole.SignalsGateway.AmbientCuration do
  @moduledoc """
  Owns ambient channel curation state: judgment records, the per-channel
  judged-until cursor, reply attribution anchors, and standing orders.

  The worker recognizer reports each `im.message.may_intervene` decision here
  before it starts (or skips) the visible turn. One transaction stores the
  judgment, applies an accepted asked_by attribution to the actor event reply
  anchor, and advances the channel cursor to the batch watermark. Standing
  orders are member-set channel policy; they only drive behavior on bindings
  whose group-message policy is `may_intervene`.
  """

  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AmbientJudgment
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ChannelContext
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Utils

  @ambient_event_type "im.message.may_intervene"
  @standing_orders_max_chars 4_000

  @doc """
  Records one recognizer judgment and advances the channel ambient cursor.

  An accepted asked_by attribution also becomes the actor event reply anchor,
  so the visible reply threads to the asking message. A worker retry for the
  same event replaces the stored judgment.
  """
  @spec record_judgment(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_judgment(agent_uid, actor_event_id, attrs) when is_map(attrs) do
    with {:ok, decision} <- decision(attrs) do
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        with {:ok, event} <- ambient_event(repo, agent_uid, actor_event_id) do
          {asked_by_id, asked_by_state} = resolve_asked_by(repo, event, attrs)
          judged_until = batch_watermark(event) || now

          with {:ok, _judgment} <-
                 upsert_judgment(repo, event, decision, attrs, asked_by_id, asked_by_state,
                   judged_until: judged_until
                 ),
               :ok <- apply_asked_anchor(repo, event, asked_by_id, asked_by_state),
               :ok <- advance_cursor(repo, event.signal_channel_id, judged_until) do
            {:ok,
             %{
               decision: decision,
               asked_by_state: asked_by_state,
               judged_until: judged_until
             }}
          end
        end
      end)
    end
  end

  @doc """
  Replaces the standing orders of the channel one actor event belongs to.

  Any member of the channel may set them through the agent; the setter is
  recorded from the triggering entry author. Empty text clears the orders.
  The result reports whether orders are active, which requires the binding
  group-message policy `may_intervene`.
  """
  @spec set_standing_orders(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def set_standing_orders(agent_uid, actor_event_id, orders) do
    with {:ok, orders} <- normalize_orders(orders) do
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        with {:ok, event} <- channel_event(repo, agent_uid, actor_event_id) do
          set_by = entry_author_name(event) || agent_uid

          case update_channel_orders(repo, event.signal_channel_id, orders, set_by, now) do
            {1, _rows} ->
              {:ok,
               %{
                 orders: orders,
                 set_by: set_by,
                 active: orders != nil and binding_may_intervene?(repo, event)
               }}

            {0, _rows} ->
              {:error, :channel_not_found}
          end
        end
      end)
    end
  end

  @doc """
  Returns the standing-orders state of one channel for the console.
  """
  @spec channel_standing_orders(String.t()) :: {:ok, map()} | {:error, :channel_not_found}
  def channel_standing_orders(channel_id) when is_binary(channel_id) do
    case Repo.get(Channel, channel_id) do
      %Channel{} = channel -> {:ok, standing_orders_projection(channel)}
      nil -> {:error, :channel_not_found}
    end
  end

  @doc """
  Replaces the standing orders of one channel from the console.
  """
  @spec put_channel_standing_orders(String.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def put_channel_standing_orders(channel_id, orders, set_by)
      when is_binary(channel_id) and is_binary(set_by) do
    with {:ok, orders} <- normalize_orders(orders) do
      now = DateTime.utc_now(:microsecond)

      case update_channel_orders(Repo, channel_id, orders, set_by, now) do
        {1, _rows} -> channel_standing_orders(channel_id)
        {0, _rows} -> {:error, :channel_not_found}
      end
    end
  end

  defp update_channel_orders(repo, channel_id, orders, set_by, now) do
    Channel
    |> where([channel], channel.id == ^channel_id)
    |> repo.update_all(
      set: [
        ambient_standing_orders: orders,
        ambient_standing_orders_set_by: set_by,
        ambient_standing_orders_updated_at: now,
        updated_at: now
      ]
    )
  end

  defp standing_orders_projection(%Channel{} = channel) do
    %{
      channel_id: channel.id,
      channel_name: channel.name,
      orders: channel.ambient_standing_orders,
      set_by: channel.ambient_standing_orders_set_by,
      updated_at: channel.ambient_standing_orders_updated_at
    }
  end

  @doc """
  Returns true when the binding of one actor event allows ambient intervention.
  """
  @spec binding_may_intervene?(module(), ActorEvent.t()) :: boolean()
  def binding_may_intervene?(repo, %ActorEvent{} = event) do
    binding =
      Binding
      |> where([binding], binding.agent_uid == ^event.agent_uid)
      |> where([binding], binding.name == ^event.binding_name)
      |> repo.one()

    match?(%Binding{unaddressed_group_message_policy: :may_intervene}, binding)
  end

  defp decision(attrs) do
    case Map.get(attrs, :decision) do
      decision when decision in ["intervene", "silent"] -> {:ok, decision}
      other -> {:error, {:invalid_ambient_decision, other}}
    end
  end

  defp ambient_event(repo, agent_uid, actor_event_id) do
    case event_for_agent(repo, agent_uid, actor_event_id) do
      {:ok, %ActorEvent{type: @ambient_event_type, signal_channel_id: channel_id} = event}
      when is_binary(channel_id) ->
        {:ok, event}

      {:ok, %ActorEvent{}} ->
        {:error, :not_an_ambient_event}

      {:error, _reason} = error ->
        error
    end
  end

  defp channel_event(repo, agent_uid, actor_event_id) do
    case event_for_agent(repo, agent_uid, actor_event_id) do
      {:ok, %ActorEvent{signal_channel_id: channel_id} = event} when is_binary(channel_id) ->
        {:ok, event}

      {:ok, %ActorEvent{}} ->
        {:error, :event_has_no_signal_channel}

      {:error, _reason} = error ->
        error
    end
  end

  defp event_for_agent(repo, agent_uid, actor_event_id) do
    case repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{agent_uid: ^agent_uid} = event -> {:ok, event}
      %ActorEvent{} -> {:error, :actor_event_agent_mismatch}
      nil -> {:error, :actor_event_not_found}
    end
  end

  # The worker validates asked_by against the judged batch; the control plane
  # only re-verifies that the entry is a real mirrored message of this channel
  # before it becomes a reply anchor.
  defp resolve_asked_by(repo, event, attrs) do
    proposed = presence(Map.get(attrs, :asked_by_source_entry_id))

    cond do
      proposed == nil ->
        {nil, nil}

      Map.get(attrs, :asked_by_degraded) == true ->
        {proposed, "degraded"}

      entry_exists?(repo, event.signal_channel_id, proposed) ->
        {proposed, "accepted"}

      true ->
        {proposed, "degraded"}
    end
  end

  defp entry_exists?(repo, signal_channel_id, source_entry_id) do
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], entry.source_entry_id == ^source_entry_id)
    |> repo.exists?()
  end

  defp upsert_judgment(repo, event, decision, attrs, asked_by_id, asked_by_state, opts) do
    %AmbientJudgment{}
    |> AmbientJudgment.changeset(%{
      actor_event_id: event.id,
      agent_uid: event.agent_uid,
      signal_channel_id: event.signal_channel_id,
      decision: decision,
      reason: Map.get(attrs, :reason) || "",
      asked_by_source_entry_id: asked_by_id,
      asked_by_state: asked_by_state,
      judged_until: Keyword.fetch!(opts, :judged_until)
    })
    |> repo.insert(
      on_conflict:
        {:replace,
         [
           :decision,
           :reason,
           :asked_by_source_entry_id,
           :asked_by_state,
           :judged_until,
           :updated_at
         ]},
      conflict_target: :actor_event_id
    )
  end

  defp apply_asked_anchor(repo, event, asked_by_id, "accepted") when is_binary(asked_by_id) do
    ActorEvent
    |> where([event_row], event_row.id == ^event.id)
    |> repo.update_all(set: [ambient_asked_source_entry_id: asked_by_id])

    :ok
  end

  defp apply_asked_anchor(_repo, _event, _asked_by_id, _state), do: :ok

  defp advance_cursor(repo, signal_channel_id, %DateTime{} = judged_until) do
    Channel
    |> where([channel], channel.id == ^signal_channel_id)
    |> update([channel],
      set: [
        ambient_judged_until:
          fragment(
            "GREATEST(COALESCE(?, ?), ?)",
            channel.ambient_judged_until,
            type(^judged_until, :utc_datetime_usec),
            type(^judged_until, :utc_datetime_usec)
          )
      ]
    )
    |> repo.update_all([])

    :ok
  end

  # The judged batch ends at the newest batch entry; later messages stay
  # unjudged for the next ambient event.
  defp batch_watermark(%ActorEvent{payload: payload}) do
    entries = get_in(payload, ["data", "entries"])

    entry_times =
      case entries do
        entries when is_list(entries) ->
          entries
          |> Enum.map(fn entry ->
            Utils.parse_datetime(map_value(entry, "sent_at") || map_value(entry, "time"))
          end)
          |> Enum.reject(&is_nil/1)

        _entries ->
          []
      end

    case entry_times do
      [_ | _] -> Enum.max_by(entry_times, &DateTime.to_unix(&1, :microsecond))
      [] -> Utils.parse_datetime(get_in(payload, ["data", "ambient_batch", "as_of"]))
    end
  end

  defp entry_author_name(%ActorEvent{payload: payload}) do
    case get_in(payload, ["data", "entry", "author"]) do
      author when is_map(author) -> ChannelContext.speaker_name(author)
      _author -> nil
    end
  end

  defp normalize_orders(orders) when is_binary(orders) do
    case String.trim(orders) do
      "" ->
        {:ok, nil}

      trimmed when byte_size(trimmed) > @standing_orders_max_chars ->
        {:error, :standing_orders_too_long}

      trimmed ->
        {:ok, trimmed}
    end
  end

  defp normalize_orders(_orders), do: {:ok, nil}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_value, _key), do: nil
end
