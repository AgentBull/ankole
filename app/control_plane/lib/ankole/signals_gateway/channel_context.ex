defmodule Ankole.SignalsGateway.ChannelContext do
  @moduledoc """
  Builds bounded shared-channel context from provider-visible SignalEntry rows.

  A provider thread identifies a reply route, not the shared room transcript:
  providers such as Lark give every top-level group message a distinct root.
  Context is therefore scoped by `signal_channel_id`; thread ids remain message
  metadata. Callers may exclude document ids already visible in one agent's
  AIGateway Response chain so the projection adds shared context without
  duplicating that agent's private conversation history.

  The same source projection also supplies the larger immutable observation
  snapshot used by ambient recognition.
  """

  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Utils

  @channel_context_max_rows 20
  @channel_context_max_tokens 2_000
  @ambient_observation_max_rows 80
  @ambient_backdrop_max_rows 10

  @doc """
  Hashes the bounded provider-visible room scene used to admit ambient work.

  Arrival identity and durable content participate in the hash; `last_seen_at`
  does not, so an exact provider redelivery cannot make an unchanged scene stale.
  """
  @spec ambient_scene_fingerprint(module(), String.t()) :: String.t()
  def ambient_scene_fingerprint(repo, signal_channel_id) when is_binary(signal_channel_id) do
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> order_by([entry], desc: entry.first_seen_at, desc: entry.document_id)
    |> limit(@ambient_observation_max_rows)
    |> repo.all()
    |> Enum.reverse()
    |> Enum.map(fn entry ->
      {entry.document_id, entry.content_hash, entry.provider_time}
    end)
    |> Utils.digest()
  end

  @doc """
  Returns recent shared-channel messages immediately before the current batch.

  The result is nil when there is no visible context, allowing the actor-event
  envelope to omit the field entirely.
  """
  def build(attrs, entries, opts \\ []) do
    case batch_boundary(attrs, entries) do
      nil ->
        nil

      boundary ->
        excluded_document_ids = Keyword.get(opts, :exclude_document_ids, [])

        messages =
          boundary
          |> entries_before_boundary(@channel_context_max_rows)
          |> exclude_document_ids(excluded_document_ids)
          |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
          |> Enum.reject(&is_nil/1)
          |> take_recent_with_token_budget()

        case messages do
          [] -> nil
          messages -> %{"messages" => messages}
        end
    end
  end

  @doc """
  Drops channel-context messages the conversation already carries.

  Turn delivery calls this after the prior turn of the same session is
  terminal, so the answer is definitive where the append-time exclusion races
  a still-generating turn: a quote survives exactly when the visible history
  does not already hold it, and a retracted turn's quotes come back. An empty
  remainder removes the whole `channel_context` block.
  """
  @spec drop_visible_messages(map(), MapSet.t()) :: map()
  def drop_visible_messages(payload, visible_refs) do
    case get_in(payload, ["data", "channel_context", "messages"]) do
      messages when is_list(messages) ->
        kept = Enum.reject(messages, &visible_message?(&1, visible_refs))

        cond do
          kept == messages -> payload
          kept == [] -> update_in(payload, ["data"], &Map.delete(&1, "channel_context"))
          true -> put_in(payload, ["data", "channel_context", "messages"], kept)
        end

      _missing ->
        payload
    end
  end

  defp visible_message?(message, visible_refs) when is_map(message) do
    case {message["signal_channel_id"], message["source_entry_id"]} do
      {channel_id, source_entry_id} when is_binary(channel_id) and is_binary(source_entry_id) ->
        MapSet.member?(visible_refs, {channel_id, source_entry_id})

      _partial ->
        false
    end
  end

  defp visible_message?(_message, _visible_refs), do: false

  @doc """
  Returns the not-yet-judged messages one ambient batch must consider.

  The window is every mirrored channel message after the channel ambient
  cursor (newest #{@ambient_observation_max_rows} rows), merged with the
  triggering batch itself so mirror lag cannot hide a batch entry. With no
  cursor the window is simply the newest mirrored rows. Messages a superseded
  ambient event never judged stay in this window until a judgment advances
  the cursor past them.
  """
  def ambient_delta_messages(
        %{signal_channel_id: signal_channel_id} = attrs,
        entries,
        judged_until
      )
      when is_binary(signal_channel_id) do
    attrs
    |> recall_entries_after(judged_until)
    |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
    |> Kernel.++(batch_observed_messages(entries))
    |> Enum.reject(&is_nil/1)
    |> dedupe_observed_messages()
    |> Enum.sort_by(&observed_sort_key/1)
    |> Enum.take(-@ambient_observation_max_rows)
  end

  def ambient_delta_messages(_attrs, entries, _judged_until), do: batch_observed_messages(entries)

  @doc """
  Returns already-judged messages immediately at or before the ambient cursor.

  They give the recognizer continuity across checks without re-offering the
  messages for judgment.
  """
  def ambient_backdrop_messages(_attrs, nil), do: []

  def ambient_backdrop_messages(
        %{signal_channel_id: signal_channel_id} = attrs,
        %DateTime{} = judged_until
      )
      when is_binary(signal_channel_id) do
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) <= ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^judged_until
      )
    )
    |> order_by([entry],
      desc:
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at),
      desc: entry.document_id
    )
    |> limit(@ambient_backdrop_max_rows)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&observed_message_from_signal_entry(&1, attrs.provider_thread_id))
    |> Enum.reject(&is_nil/1)
  end

  def ambient_backdrop_messages(_attrs, _judged_until), do: []

  @doc """
  Returns the current finalized batch as observed-message rows.
  """
  def batch_observed_messages(entries) do
    entries
    |> Enum.map(&observed_message_from_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns human messages since the latest mirrored agent reply.
  """
  def unreplied_messages(attrs, entries) do
    case batch_boundary(attrs, entries) do
      nil ->
        []

      boundary ->
        entries = entries_before_boundary(boundary, @ambient_observation_max_rows)
        agent_cutoff = latest_agent_sent_at(entries)

        entries
        |> Enum.filter(&(entry_role(&1) != "agent"))
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
          start_at: Enum.min_by(times, &DateTime.to_unix(&1, :microsecond)),
          end_at: Enum.max_by(times, &DateTime.to_unix(&1, :microsecond))
        }

      _value ->
        nil
    end
  end

  defp recall_entries_after(attrs, judged_until) do
    Entry
    |> where([entry], entry.signal_channel_id == ^attrs.signal_channel_id)
    |> entries_after_cursor(judged_until)
    |> order_by([entry],
      desc:
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at),
      desc: entry.document_id
    )
    |> limit(@ambient_observation_max_rows)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp entries_after_cursor(query, nil), do: query

  defp entries_after_cursor(query, %DateTime{} = judged_until) do
    where(
      query,
      [entry],
      fragment(
        "COALESCE(?, ?, ?) > ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^judged_until
      )
    )
  end

  defp entries_before_boundary(boundary, limit) do
    Entry
    |> where([entry], entry.signal_channel_id == ^boundary.signal_channel_id)
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
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at),
      desc: entry.document_id
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp exclude_document_ids(entries, []), do: entries

  defp exclude_document_ids(entries, document_ids) when is_list(document_ids) do
    excluded = MapSet.new(document_ids)
    Enum.reject(entries, &MapSet.member?(excluded, &1.document_id))
  end

  defp observed_message_from_entry(entry) when is_map(entry) do
    text = optional_text(entry, :text)
    sent_at = optional_text(entry, :sent_at) || optional_text(entry, :time)

    case {text, sent_at} do
      {text, sent_at} when is_binary(text) and is_binary(sent_at) ->
        %{
          "id" => "batch:#{entry["source_entry_id"] || :erlang.phash2(entry)}",
          "source" => "ambient_batch",
          "role" => "human",
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
    case entry.text do
      text when is_binary(text) and text != "" ->
        %{
          "id" => "signal:#{entry.signal_channel_id}:#{entry.source_entry_id}",
          "source" => "signal_entry",
          "role" => entry_role(entry),
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

  defp take_recent_with_token_budget(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn message, {accepted, total_tokens} ->
      tokens =
        message
        |> model_visible_message_text()
        |> Ankole.Kernel.estimate_o200k_base_tokens()

      if total_tokens + tokens <= @channel_context_max_tokens do
        {:cont, {[message | accepted], total_tokens + tokens}}
      else
        {:halt, {accepted, total_tokens}}
      end
    end)
    |> elem(0)
  end

  defp model_visible_message_text(message) do
    [message["sent_at"], message["role"], message["speaker"], message["text"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
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

  @doc """
  Tells whether one mirrored entry came from a person or from an own Agent.

  Only an entry the gateway posted itself carries `agent_uid`, so its presence is
  the durable discriminator.
  """
  @spec entry_role(term()) :: String.t()
  def entry_role(%Entry{author: author}) when is_map(author) do
    case optional_text(author, :agent_uid) do
      nil -> "human"
      _agent_uid -> "agent"
    end
  end

  def entry_role(_entry), do: "human"

  defp latest_agent_sent_at(entries) do
    entries
    |> Enum.filter(&(entry_role(&1) == "agent"))
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

  defp signal_entry_provider_thread_id(%Entry{} = entry), do: entry.provider_thread_id

  @doc """
  Returns the display name of one entry author map.
  """
  @spec speaker_name(term()) :: String.t()
  def speaker_name(author), do: author_name(author) || "unknown speaker"

  @doc """
  Names one entry author, or returns nil when the map names nobody.

  A provider only fills `display_name` when its webhook carries a name, and an
  entry an own Agent posted carries `agent_uid` alone, so a projection that keeps
  its shorter chain silently loses the speaker. Callers that must always show a
  speaker use `speaker_name/1`.
  """
  @spec author_name(term()) :: String.t() | nil
  def author_name(author) when is_map(author) do
    optional_text(author, :display_name) ||
      optional_text(author, :fullName) ||
      optional_text(author, :userName) ||
      optional_text(author, :name) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :agent_uid)
  end

  def author_name(_author), do: nil

  defp parse_iso8601(%DateTime{} = datetime), do: datetime

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_iso8601(_value), do: nil

  defp optional_text(map, key) when is_map(map) do
    atom_value = if is_atom(key), do: Map.get(map, key)
    string_value = Map.get(map, to_string(key))

    case atom_value || string_value do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end
end
