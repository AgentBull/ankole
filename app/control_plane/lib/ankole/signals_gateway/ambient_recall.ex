defmodule Ankole.SignalsGateway.AmbientRecall do
  @moduledoc """
  Builds observed-message snapshots for ambient recognition batches.

  Ambient batches need the recent room scene, not just the gateway events that
  happened to arrive in one process. The snapshot is immutable worker input and
  keeps the recall query out of the worker.
  """

  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Entry

  @ambient_recall_max_rows 80
  @ambient_recent_history_rows 10

  @doc """
  Returns the observed messages visible to one ambient batch.
  """
  def observed_messages(attrs, entries) do
    case batch_boundary(attrs, entries) do
      nil ->
        batch_observed_messages(entries)

      boundary ->
        attrs
        |> recall_signal_observed_messages(boundary)
        |> Kernel.++(batch_observed_messages(entries))
        |> Enum.reject(&is_nil/1)
        |> dedupe_observed_messages()
        |> Enum.sort_by(&observed_sort_key/1)
        |> Enum.take(@ambient_recall_max_rows)
    end
  end

  @doc """
  Returns the current finalized batch as observed-message rows.
  """
  def batch_observed_messages(entries) do
    entries
    |> Enum.map(&observed_message_from_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the visible transcript immediately before the ambient batch.
  """
  def recent_history(attrs, entries, limit \\ @ambient_recent_history_rows) do
    case batch_boundary(attrs, entries) do
      nil ->
        []

      boundary ->
        boundary
        |> entries_before_boundary(limit)
        |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Returns unreplied ambient messages since the latest mirrored agent reply.
  """
  def earlier_observed_messages(attrs, entries) do
    case batch_boundary(attrs, entries) do
      nil ->
        []

      boundary ->
        entries = entries_before_boundary(boundary, @ambient_recall_max_rows)
        agent_cutoff = latest_agent_sent_at(entries)

        entries
        |> Enum.filter(&(signal_entry_role(&1) != "agent"))
        |> Enum.filter(&after_cutoff?(&1, agent_cutoff))
        |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp batch_boundary(attrs, entries) do
    times =
      entries
      |> Enum.flat_map(fn entry ->
        case parse_iso8601(entry["sent_at"] || entry["time"]) do
          %DateTime{} = sent_at -> [sent_at]
          nil -> []
        end
      end)

    signal_channel_id =
      Enum.find_value(entries, attrs.signal_channel_id, fn entry ->
        case entry["signal_channel_id"] do
          channel_id when is_binary(channel_id) -> channel_id
          _value -> false
        end
      end)

    case {signal_channel_id, times} do
      {channel_id, [_ | _]} when is_binary(channel_id) ->
        %{
          signal_channel_id: channel_id,
          provider_thread_id: attrs.provider_thread_id,
          start_at: Enum.min_by(times, &DateTime.to_unix(&1, :microsecond)),
          end_at: Enum.max_by(times, &DateTime.to_unix(&1, :microsecond))
        }

      _value ->
        nil
    end
  end

  defp recall_signal_observed_messages(attrs, boundary) do
    Entry
    |> where([entry], entry.signal_channel_id == ^boundary.signal_channel_id)
    |> maybe_where_provider_thread(boundary.provider_thread_id)
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) >= ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^boundary.start_at
      )
    )
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) <= ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^boundary.end_at
      )
    )
    |> order_by([entry],
      asc:
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at)
    )
    |> limit(@ambient_recall_max_rows)
    |> Repo.all()
    |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
  end

  defp entries_before_boundary(boundary, limit) do
    Entry
    |> where([entry], entry.signal_channel_id == ^boundary.signal_channel_id)
    |> maybe_where_provider_thread(boundary.provider_thread_id)
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) < ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^boundary.start_at
      )
    )
    |> order_by([entry],
      desc:
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at)
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp maybe_where_provider_thread(query, nil), do: query

  defp maybe_where_provider_thread(query, provider_thread_id) do
    where(
      query,
      [entry],
      is_nil(entry.provider_thread_id) or entry.provider_thread_id == ^provider_thread_id
    )
  end

  defp observed_message_from_entry(entry) when is_map(entry) do
    text = optional_text(entry, :text)
    sent_at = optional_text(entry, :sent_at) || optional_text(entry, :time)

    case {text, sent_at} do
      {text, sent_at} when is_binary(text) and is_binary(sent_at) ->
        %{
          "id" => "batch:#{entry["source_entry_id"] || :erlang.phash2(entry)}",
          "source" => "ambient_batch",
          "role" => "ambient_human",
          "kind" => "normal",
          "speaker" => speaker_name(entry["author"]),
          "sent_at" => sent_at,
          "text" => text,
          "signal_channel_id" => entry["signal_channel_id"],
          "source_entry_id" => entry["source_entry_id"],
          "provider_thread_id" => entry["provider_thread_id"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp observed_message_from_entry(_entry), do: nil

  defp observed_message_from_signal_entry(%Entry{} = entry, provider_thread_id) do
    text = entry.text

    case text do
      text when is_binary(text) ->
        %{
          "id" => "signal:#{entry.signal_channel_id}:#{entry.source_entry_id}",
          "source" => "signal_entry",
          "role" => signal_entry_role(entry),
          "kind" => "normal",
          "speaker" => speaker_name(entry.author),
          "sent_at" => DateTime.to_iso8601(signal_entry_sent_at(entry)),
          "text" => text,
          "signal_channel_id" => entry.signal_channel_id,
          "source_entry_id" => entry.source_entry_id,
          "provider_thread_id" => signal_entry_provider_thread_id(entry) || provider_thread_id
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp dedupe_observed_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.uniq_by(fn message ->
      provider_key =
        case {message["signal_channel_id"], message["source_entry_id"]} do
          {channel_id, entry_id} when is_binary(channel_id) and is_binary(entry_id) ->
            "#{channel_id}:#{entry_id}"

          _value ->
            nil
        end

      provider_key || message["id"]
    end)
    |> Enum.reverse()
  end

  defp observed_sort_key(message) do
    case parse_iso8601(message["sent_at"]) do
      %DateTime{} = sent_at -> DateTime.to_unix(sent_at, :microsecond)
      nil -> 0
    end
  end

  defp signal_entry_role(%Entry{author: author}) when is_map(author) do
    case optional_text(author, :agent_uid) do
      nil -> "ambient_human"
      _agent_uid -> "agent"
    end
  end

  defp signal_entry_role(_entry), do: "ambient_human"

  defp latest_agent_sent_at(entries) do
    entries
    |> Enum.filter(&(signal_entry_role(&1) == "agent"))
    |> List.last()
    |> case do
      %Entry{} = entry -> signal_entry_sent_at(entry)
      nil -> nil
    end
  end

  defp after_cutoff?(_entry, nil), do: true

  defp after_cutoff?(entry, %DateTime{} = cutoff) do
    DateTime.compare(signal_entry_sent_at(entry), cutoff) == :gt
  end

  defp signal_entry_sent_at(%Entry{provider_time: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%Entry{last_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%Entry{inserted_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%Entry{first_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(_entry), do: DateTime.utc_now(:microsecond)

  defp signal_entry_provider_thread_id(%Entry{} = entry) do
    entry.provider_thread_id
  end

  defp speaker_name(author) when is_map(author) do
    optional_text(author, :display_name) ||
      optional_text(author, :fullName) ||
      optional_text(author, :userName) ||
      optional_text(author, :name) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :agent_uid) ||
      "unknown speaker"
  end

  defp speaker_name(_author), do: "unknown speaker"

  defp parse_iso8601(%DateTime{} = datetime), do: datetime

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_iso8601(_value), do: nil

  defp optional_text(map, key) when is_map(map) do
    atom_value =
      if is_atom(key) do
        Map.get(map, key)
      end

    string_value = Map.get(map, to_string(key))

    case atom_value || string_value do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end
end
