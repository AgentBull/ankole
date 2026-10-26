defmodule Ankole.Conversations.MessageInput do
  @moduledoc """
  Computes revisions to message-backed Signal input without changing execution state.

  InputRevisions owns queued input and revision intake. Sessions.Revisions owns
  in-flight execution. Both apply these changes inside their existing transactions.
  """

  import Ankole.Attrs, only: [parse_datetime: 1]

  alias Ankole.Signals.Signal

  @doc "Computes normalized input changes without changing execution state."
  def revised_input_attrs(event, kind, entry, now) when kind in ["edit", "supplement"] do
    entries = input_entries(event)

    entries =
      if entries == [],
        do: List.wrap(get_in(Signal.envelope(event), ["data", "entry"])),
        else: entries

    entries = upsert_event_entry(entries, entry)

    {:update,
     %{
       data: supplement_payload(Signal.envelope(event), entries, event.id, now)["data"],
       occurred_at: now,
       provider_message_id: merged_entry_summary(entries)["provider_message_id"],
       available_at: pending_attachment_deadline(entries, now) || now
     }}
  end

  def revised_input_attrs(event, "remove", entry, now) do
    case source_entry_retraction(input_entries(event), event, entry["provider_message_id"]) do
      {:replace, entries} ->
        summary = merged_entry_summary(entries)

        payload =
          replace_payload_entries(
            Signal.envelope(event),
            entries,
            summary,
            entry["provider_message_id"],
            now
          )

        {:update,
         %{
           data: payload["data"],
           occurred_at: now,
           provider_message_id: summary["provider_message_id"],
           available_at: now
         }}

      other ->
        other
    end
  end

  @attachment_materialization_hard_cap_ms 4_000

  defp supplement_payload(payload, entries, signal_id, now) do
    summary = merged_entry_summary(entries)

    payload
    |> replace_payload_entries(entries, summary, nil, now)
    |> Signal.put_retry_metadata(signal_id, "input_superseded", %{
      "supplement_provider_message_ids" =>
        entries
        |> Enum.filter(
          &(attachment_materialization_state(&1) in ["pending", "complete", "failed"])
        )
        |> Enum.map(& &1["provider_message_id"])
    })
  end

  defp upsert_event_entry(entries, entry) do
    entries
    |> Enum.reject(&(&1["provider_message_id"] == entry["provider_message_id"]))
    |> Kernel.++([entry])
    |> Enum.sort_by(fn value ->
      {
        value["provider_time"] || value["sent_at"] || "",
        value["received_at"] || value["sent_at"] || "",
        value["provider_message_id"] || ""
      }
    end)
  end

  @doc "Returns the earliest pending attachment deadline, or nil when none remain."
  def pending_attachment_deadline(entries, now) do
    entries
    |> Enum.filter(&(attachment_materialization_state(&1) == "pending"))
    |> Enum.map(fn entry ->
      anchor =
        attachment_observed_at(entry) ||
          parse_datetime(entry["received_at"]) ||
          now

      DateTime.add(anchor, @attachment_materialization_hard_cap_ms, :millisecond)
    end)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  def attachment_observed_at(entry) when is_map(entry) do
    entry
    |> get_in(["metadata", "attachment_materialization", "observed_at"])
    |> parse_datetime()
  end

  def attachment_observed_at(_entry), do: nil

  def attachment_materialization_state(entry) when is_map(entry),
    do: get_in(entry, ["metadata", "attachment_materialization", "state"])

  def attachment_materialization_state(_entry), do: nil

  defp source_entry_retraction(entries, %Signal{}, provider_message_id)
       when is_list(entries) and entries != [] do
    remaining = Enum.reject(entries, &(&1["provider_message_id"] == provider_message_id))

    cond do
      length(remaining) == length(entries) -> :no_match
      remaining == [] -> :cancel
      true -> {:replace, remaining}
    end
  end

  defp source_entry_retraction(
         _entries,
         %Signal{provider_message_id: direct_entry_id},
         provider_message_id
       )
       when direct_entry_id == provider_message_id,
       do: :cancel

  defp source_entry_retraction(_entries, _input, _provider_message_id), do: :no_match

  defp replace_payload_entries(payload, entries, summary, removed_provider_message_id, now)
       when is_map(payload) do
    data = Map.get(payload, "data", %{})

    data =
      data
      |> Map.put("entry", summary)
      |> Map.put("entries", entries)
      |> refresh_command()
      |> update_observed_messages(removed_provider_message_id)
      |> update_ambient_batch(entries, now)

    Map.put(payload, "data", data)
  end

  defp replace_payload_entries(_payload, entries, summary, _removed_provider_message_id, _now) do
    %{"data" => %{"entry" => summary, "entries" => entries}}
  end

  defp refresh_command(%{"command" => %{"name" => name} = command} = data) do
    case Ankole.Signals.Commands.classify(get_in(data, ["entry", "text"])) do
      {:ok, %{"name" => ^name} = current} ->
        Map.put(data, "command", Map.merge(command, current))

      _revised_text ->
        Map.delete(data, "command")
    end
  end

  defp refresh_command(data), do: data

  defp update_observed_messages(data, removed_provider_message_id) do
    Enum.reduce(["observed_messages", "backdrop_messages", "unreplied_messages"], data, fn key,
                                                                                           data ->
      case Map.get(data, key) do
        messages when is_list(messages) ->
          Map.put(
            data,
            key,
            Enum.reject(messages, &(&1["provider_message_id"] == removed_provider_message_id))
          )

        _value ->
          data
      end
    end)
  end

  defp update_ambient_batch(%{"ambient_batch" => batch} = data, entries, now)
       when is_map(batch) do
    batch =
      batch
      |> Map.put("size", length(entries))
      |> Map.put(
        "first_provider_message_id",
        entries |> List.first() |> Map.get("provider_message_id")
      )
      |> Map.put(
        "last_provider_message_id",
        entries |> List.last() |> Map.get("provider_message_id")
      )
      |> Map.put("updated_at", DateTime.to_iso8601(now))

    Map.put(data, "ambient_batch", batch)
  end

  defp update_ambient_batch(data, _entries, _now), do: data

  defp merged_entry_summary(entries) do
    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", merged_entry_text(entries))
    |> put_nonempty("attachments", merged_entry_list(entries, "attachments"))
    |> put_nonempty("links", merged_entry_list(entries, "links"))
    |> put_nonempty("mentions", merged_entry_list(entries, "mentions"))
  end

  def merged_entry_text(entries) do
    entries
    |> Enum.map(& &1["text"])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  def merged_entry_list(entries, key) do
    Enum.flat_map(entries, fn entry ->
      case entry[key] do
        values when is_list(values) -> values
        _value -> []
      end
    end)
  end

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, values), do: Map.put(map, key, values)

  def input_entries(%Signal{data: %{"entries" => entries}})
      when is_list(entries),
      do: entries

  def input_entries(_input), do: []
end
