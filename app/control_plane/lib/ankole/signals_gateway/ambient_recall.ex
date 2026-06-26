defmodule Ankole.SignalsGateway.AmbientRecall do
  @moduledoc """
  Builds observed-message snapshots for ambient recognition batches.

  Ambient batches need the recent room scene, not just the gateway events that
  happened to arrive in one process. The snapshot is immutable worker input and
  keeps the recall query out of the worker.
  """

  import Ecto.Query

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Repo
  alias Ankole.SignalsGateway.SignalEntry

  @ambient_recall_max_rows 80

  @doc """
  Returns the observed messages visible to one ambient batch.
  """
  def observed_messages(attrs, entries) do
    case batch_boundary(attrs, entries) do
      nil ->
        entries
        |> Enum.map(&observed_message_from_entry/1)
        |> Enum.reject(&is_nil/1)

      boundary ->
        attrs
        |> recall_signal_observed_messages(boundary)
        |> Kernel.++(recall_conversation_observed_messages(attrs, boundary))
        |> Kernel.++(Enum.map(entries, &observed_message_from_entry/1))
        |> Enum.reject(&is_nil/1)
        |> dedupe_observed_messages()
        |> Enum.sort_by(&observed_sort_key/1)
        |> Enum.take(@ambient_recall_max_rows)
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
      entries
      |> Enum.map(& &1["signal_channel_id"])
      |> Enum.find(&is_binary/1) ||
        attrs.signal_channel_id

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
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^boundary.signal_channel_id)
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
    |> Enum.filter(&same_provider_thread?(&1, boundary.provider_thread_id))
    |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
  end

  defp recall_conversation_observed_messages(attrs, boundary) do
    with %Conversation{} = conversation <- active_conversation(attrs.agent_uid, attrs.session_id) do
      Message
      |> where([message], message.conversation_id == ^conversation.id)
      |> where([message], message.role in ["assistant", "tool", "im_ambient"])
      |> where([message], message.inserted_at >= ^boundary.start_at)
      |> where([message], message.inserted_at <= ^boundary.end_at)
      |> order_by([message], asc: message.inserted_at)
      |> limit(@ambient_recall_max_rows)
      |> Repo.all()
      |> Enum.filter(&message_in_boundary?(&1, boundary))
      |> Enum.map(&observed_message_from_conversation/1)
    else
      nil -> []
    end
  end

  defp active_conversation(agent_uid, session_id) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^normalize_uid(agent_uid))
    |> where([conversation], conversation.conversation_key == ^session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> Repo.one()
  end

  defp message_in_boundary?(%Message{} = message, boundary) do
    with true <- message_signal_channel_id(message) == boundary.signal_channel_id,
         true <- message_provider_thread_matches?(message, boundary.provider_thread_id),
         %DateTime{} = sent_at <- message_sent_at(message) do
      DateTime.compare(sent_at, boundary.start_at) != :lt and
        DateTime.compare(sent_at, boundary.end_at) != :gt
    else
      _value -> false
    end
  end

  defp same_provider_thread?(_entry, nil), do: true

  defp same_provider_thread?(%SignalEntry{} = entry, provider_thread_id) do
    case signal_entry_provider_thread_id(entry) do
      nil -> true
      ^provider_thread_id -> true
      _other -> false
    end
  end

  defp message_provider_thread_matches?(_message, nil), do: true

  defp message_provider_thread_matches?(%Message{} = message, provider_thread_id) do
    case message_provider_thread_id(message) do
      nil -> true
      ^provider_thread_id -> true
      _other -> false
    end
  end

  defp observed_message_from_entry(entry) when is_map(entry) do
    text = optional_text(entry, :text)
    sent_at = optional_text(entry, :sent_at) || optional_text(entry, :time)

    case {text, sent_at} do
      {text, sent_at} when is_binary(text) and is_binary(sent_at) ->
        %{
          "id" => "batch:#{entry["provider_entry_id"] || :erlang.phash2(entry)}",
          "source" => "ambient_batch",
          "role" => "ambient_human",
          "kind" => "normal",
          "speaker" => speaker_name(entry["author"]),
          "sent_at" => sent_at,
          "text" => text,
          "signal_channel_id" => entry["signal_channel_id"],
          "provider_entry_id" => entry["provider_entry_id"],
          "provider_thread_id" => entry["provider_thread_id"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp observed_message_from_entry(_entry), do: nil

  defp observed_message_from_signal_entry(%SignalEntry{} = entry, provider_thread_id) do
    text = entry.text || entry.fallback_visible_text

    case text do
      text when is_binary(text) ->
        %{
          "id" => "signal:#{entry.signal_channel_id}:#{entry.provider_entry_id}",
          "source" => "signal_entry",
          "role" => signal_entry_role(entry),
          "kind" => "normal",
          "speaker" => speaker_name(entry.author),
          "sent_at" => DateTime.to_iso8601(signal_entry_sent_at(entry)),
          "text" => text,
          "signal_channel_id" => entry.signal_channel_id,
          "provider_entry_id" => entry.provider_entry_id,
          "provider_thread_id" => signal_entry_provider_thread_id(entry) || provider_thread_id
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp observed_message_from_conversation(%Message{} = message) do
    text = message_text(message)

    case text do
      text when is_binary(text) ->
        %{
          "id" => "conversation:#{message.id}",
          "source" => "ai_agent_messages",
          "role" => conversation_observed_role(message),
          "kind" => message.kind,
          "speaker" => message_speaker(message),
          "sent_at" => message_sent_at(message) |> DateTime.to_iso8601(),
          "text" => text,
          "signal_channel_id" => message_signal_channel_id(message),
          "provider_entry_id" => message_provider_entry_id(message),
          "provider_thread_id" => message_provider_thread_id(message)
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
        case {message["signal_channel_id"], message["provider_entry_id"]} do
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

  defp signal_entry_role(%SignalEntry{author: author}) when is_map(author) do
    case optional_text(author, :agent_uid) do
      nil -> "ambient_human"
      _agent_uid -> "agent"
    end
  end

  defp signal_entry_role(_entry), do: "ambient_human"

  defp signal_entry_sent_at(%SignalEntry{provider_time: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{last_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{inserted_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{first_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(_entry), do: DateTime.utc_now(:microsecond)

  defp signal_entry_provider_thread_id(%SignalEntry{} = entry) do
    optional_text(entry.metadata || %{}, :provider_thread_id) ||
      optional_text(entry.raw_payload || %{}, :provider_thread_id)
  end

  defp conversation_observed_role(%Message{role: "assistant"}), do: "agent"
  defp conversation_observed_role(%Message{role: "tool"}), do: "tool"

  defp conversation_observed_role(%Message{role: "im_ambient", kind: "introspection"}),
    do: "runtime"

  defp conversation_observed_role(%Message{role: "im_ambient"}), do: "ambient_human"
  defp conversation_observed_role(%Message{}), do: "human"

  defp message_speaker(%Message{role: "assistant", agent_uid: agent_uid}), do: agent_uid
  defp message_speaker(%Message{role: "tool"}), do: "tool"

  defp message_speaker(%Message{role: "im_ambient", kind: "introspection"}),
    do: "Ankole runtime"

  defp message_speaker(%Message{metadata: metadata}) do
    speaker_name(
      get_in(metadata || %{}, ["message_context", "actor"]) ||
        Map.get(metadata || %{}, "actor")
    )
  end

  defp message_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp message_text(_message), do: nil

  defp message_signal_channel_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :signal_channel_id) ||
      get_in(metadata, ["provider_refs", "room_id"]) ||
      get_in(metadata, ["route", "provider_room_id"]) ||
      get_in(metadata, ["message_context", "room", "id"])
  end

  defp message_provider_entry_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :provider_entry_id) ||
      get_in(metadata, ["provider_refs", "provider_message_id"])
  end

  defp message_provider_thread_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :provider_thread_id) ||
      get_in(metadata, ["provider_refs", "thread_id"]) ||
      get_in(metadata, ["route", "provider_thread_id"])
  end

  defp message_sent_at(%Message{metadata: metadata, inserted_at: inserted_at}) do
    metadata_sent_at = get_in(metadata || %{}, ["message_context", "time", "sent_at"])

    parse_iso8601(metadata_sent_at) || inserted_at || DateTime.utc_now(:microsecond)
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

  defp optional_text(_map, _key), do: nil

  defp normalize_uid(uid) when is_binary(uid), do: uid |> String.trim() |> String.downcase()
  defp normalize_uid(uid), do: uid
end
