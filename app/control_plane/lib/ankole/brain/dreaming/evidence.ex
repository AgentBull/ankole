defmodule Ankole.Brain.Dreaming.Evidence do
  @moduledoc false

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIReplyText

  @spec task_outcome(ActorEvent.t(), [Message.t()]) :: map() | nil
  def task_outcome(%ActorEvent{} = event, messages) when is_list(messages) do
    request = request_messages(event.payload)
    final_response = final_response(messages)
    tools_used = tool_activity(messages)

    if request == [] and is_nil(final_response) and tools_used == [] do
      nil
    else
      %{
        trigger: event.type,
        request: request,
        final_response: final_response,
        tools_used: tools_used
      }
    end
  end

  @spec curator_material(map(), String.t()) :: map()
  def curator_material(%{kind: :signal_message} = material, timezone) do
    compact(%{
      "material_id" => material.document_id,
      "kind" => "signal_message",
      "observed_at" => local_time(material.observed_at, timezone),
      "channel" => channel(material),
      "speaker" => Map.get(material, :speaker),
      "text" => material.text || ""
    })
  end

  def curator_material(%{kind: :task_outcome} = material, timezone) do
    compact(%{
      "material_id" => material.actor_event_id,
      "kind" => "task_outcome",
      "completed_at" => local_time(material.observed_at, timezone),
      "trigger" => material.trigger,
      "channel" => channel(material),
      "request" => material.request,
      "final_response" => material.final_response,
      "tools_used" => material.tools_used
    })
  end

  @spec locator_material(map(), String.t(), non_neg_integer()) :: map()
  def locator_material(material, timezone, preview_characters) do
    projected = curator_material(material, timezone)
    text = preview_text(material)
    preview = String.slice(text, 0, preview_characters)

    projected
    |> Map.drop(["text", "request", "final_response"])
    |> Map.put("preview", preview)
    |> Map.put("preview_truncated", preview != text)
  end

  defp request_messages(payload) do
    payload
    |> request_entries()
    |> Enum.flat_map(&normalize_request_message/1)
  end

  defp request_entries(%{"data" => data}) when is_map(data) do
    entries =
      case data["entries"] do
        entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
        _missing -> []
      end

    case entries do
      [] ->
        case data["entry"] do
          entry when is_map(entry) -> [entry]
          _missing -> []
        end

      entries ->
        entries
    end
  end

  defp request_entries(_payload), do: []

  defp normalize_request_message(entry) do
    case nonempty_text(entry["text"]) do
      nil ->
        []

      text ->
        [
          compact(%{
            "speaker" => request_speaker(entry),
            "text" => text
          })
        ]
    end
  end

  defp request_speaker(%{"speaker" => speaker}) when is_binary(speaker),
    do: nonempty_text(speaker)

  defp request_speaker(%{"author" => %{"display_name" => name}}) when is_binary(name),
    do: nonempty_text(name)

  defp request_speaker(%{"author" => %{"principal_uid" => uid}}) when is_binary(uid),
    do: nonempty_text(uid)

  defp request_speaker(_entry), do: nil

  defp final_response(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      case AIReplyText.visible_text(message.content) do
        text when is_binary(text) ->
          if String.trim(text) == AIReplyText.silent_success_marker(), do: nil, else: text

        nil ->
          nil
      end
    end)
  end

  defp tool_activity(messages) do
    items = Enum.flat_map(messages, & &1.content)

    calls =
      items
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn
        {%{"type" => "function_call", "name" => name} = item, index}, acc
        when is_binary(name) ->
          case nonempty_text(name) do
            nil -> acc
            name -> Map.put_new(acc, call_key(item, index), name)
          end

        {_item, _index}, acc ->
          acc
      end)

    result_ids =
      Enum.reduce(items, MapSet.new(), fn
        %{"type" => "function_call_output", "call_id" => call_id}, acc
        when is_binary(call_id) ->
          MapSet.put(acc, call_id)

        _item, acc ->
          acc
      end)

    calls
    |> Enum.group_by(fn {_call_id, name} -> name end)
    |> Enum.map(fn {name, named_calls} ->
      %{
        "name" => name,
        "call_count" => length(named_calls),
        "result_count" =>
          Enum.count(named_calls, fn {call_id, _name} -> MapSet.member?(result_ids, call_id) end)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp call_key(%{"call_id" => call_id}, _index) when is_binary(call_id), do: call_id
  defp call_key(%{"id" => id}, _index) when is_binary(id), do: id
  defp call_key(_item, index), do: "anonymous:#{index}"

  defp preview_text(%{kind: :signal_message} = material), do: material.text || ""

  defp preview_text(%{kind: :task_outcome} = material) do
    request_text = material.request |> Enum.map(& &1["text"]) |> Enum.join("\n")

    [request_text, material.final_response]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp channel(material) do
    compact(%{
      "id" => Map.get(material, :channel_id),
      "kind" => Map.get(material, :channel_kind),
      "name" => Map.get(material, :channel_name)
    })
    |> case do
      empty when map_size(empty) == 0 -> nil
      channel -> channel
    end
  end

  defp local_time(%DateTime{} = datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, local} ->
        Calendar.strftime(local, "%Y-%m-%d %H:%M:%S") <> " (#{timezone})"

      {:error, _reason} ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S") <> " (Etc/UTC)"
    end
  end

  defp nonempty_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp nonempty_text(_value), do: nil

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
