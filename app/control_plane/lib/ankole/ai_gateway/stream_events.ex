defmodule Ankole.AIGateway.StreamEvents do
  @moduledoc """
  Builds stateless SSE event sequences from a completed Responses body.

  This is used when the upstream call is non-streaming but the downstream client
  requested SSE. It emits the same public event vocabulary as live upstream SSE
  normalization so HTTP SSE and WebSocket consumers can share one parser.
  """

  @doc """
  Converts a completed response body into Responses streaming events.
  """
  @spec response_stream_events(map()) :: [map()]
  def response_stream_events(body) when is_map(body) do
    terminal_event =
      case Map.get(body, "status") do
        "failed" -> "response.failed"
        "incomplete" -> "response.incomplete"
        _status -> "response.completed"
      end

    {item_events, next_sequence} =
      body
      |> Map.get("output", [])
      |> output_stream_events(1)

    [
      %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => body
      }
      | item_events
    ] ++
      [
        %{
          "type" => terminal_event,
          "sequence_number" => next_sequence,
          "response" => body
        }
      ]
  end

  defp output_stream_events(output, sequence) when is_list(output) do
    output
    |> Enum.with_index()
    |> Enum.reduce({[], sequence}, fn {item, output_index}, {events, sequence} ->
      {item_events, next_sequence} = item_stream_events(item, output_index, sequence)
      {events ++ item_events, next_sequence}
    end)
  end

  defp output_stream_events(_output, sequence), do: {[], sequence}

  defp item_stream_events(%{"id" => item_id, "content" => content} = item, output_index, sequence)
       when is_list(content) do
    item_content_stream_events(item_id, item, "content", content, output_index, sequence)
  end

  defp item_stream_events(%{"id" => item_id, "summary" => summary} = item, output_index, sequence)
       when is_list(summary) do
    item_content_stream_events(item_id, item, "summary", summary, output_index, sequence)
  end

  defp item_stream_events(item, output_index, sequence) when is_map(item) do
    item = Map.put_new(item, "status", "completed")

    events = [
      %{
        "type" => "response.output_item.added",
        "sequence_number" => sequence,
        "output_index" => output_index,
        "item" => %{item | "status" => "in_progress"}
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => sequence + 1,
        "output_index" => output_index,
        "item" => item
      }
    ]

    {events, sequence + 2}
  end

  defp item_stream_events(_item, _output_index, sequence), do: {[], sequence}

  # Message `content` and reasoning `summary` are different fields but share the
  # same lifecycle: output item added, content part added, semantic delta/done,
  # content part done, output item done.
  defp item_content_stream_events(item_id, item, field, parts, output_index, sequence) do
    item =
      item
      |> Map.put_new("status", "completed")

    added = %{
      "type" => "response.output_item.added",
      "sequence_number" => sequence,
      "output_index" => output_index,
      "item" =>
        item
        |> Map.put("status", "in_progress")
        |> Map.put(field, [])
    }

    {content_events, sequence} =
      parts
      |> Enum.with_index()
      |> Enum.reduce({[], sequence + 1}, fn {part, content_index}, {events, sequence} ->
        {part_events, next_sequence} =
          content_part_stream_events(part, item_id, output_index, content_index, sequence)

        {events ++ part_events, next_sequence}
      end)

    done = %{
      "type" => "response.output_item.done",
      "sequence_number" => sequence,
      "output_index" => output_index,
      "item" => item
    }

    {[added | content_events] ++ [done], sequence + 1}
  end

  defp content_part_stream_events(part, item_id, output_index, content_index, sequence)
       when is_map(part) do
    case streamable_content_part(part) do
      {:ok, event_suffix, field, value} ->
        content_stream_events(
          part,
          event_suffix,
          field,
          value,
          item_id,
          output_index,
          content_index,
          sequence
        )

      :error ->
        generic_content_part_events(part, item_id, output_index, content_index, sequence)
    end
  end

  defp content_part_stream_events(_part, _item_id, _output_index, _content_index, sequence),
    do: {[], sequence}

  # Only content parts with a semantic delta event are split into delta/done
  # events. Unknown parts still get added/done lifecycle events so the sequence
  # remains lossless.
  defp streamable_content_part(%{"type" => "output_text", "text" => text}),
    do: {:ok, "output_text", "text", to_string(text)}

  defp streamable_content_part(%{"type" => "summary_text", "text" => text}),
    do: {:ok, "summary_text", "text", to_string(text)}

  defp streamable_content_part(%{"type" => "refusal", "refusal" => refusal}),
    do: {:ok, "refusal", "refusal", to_string(refusal)}

  defp streamable_content_part(_part), do: :error

  defp content_stream_events(
         part,
         event_suffix,
         field,
         value,
         item_id,
         output_index,
         content_index,
         sequence
       ) do
    events = [
      %{
        "type" => "response.content_part.added",
        "sequence_number" => sequence,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        "part" => Map.put(part, field, "")
      },
      %{
        "type" => "response.#{event_suffix}.delta",
        "sequence_number" => sequence + 1,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        "delta" => value
      },
      %{
        "type" => "response.#{event_suffix}.done",
        "sequence_number" => sequence + 2,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        field => value
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => sequence + 3,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        "part" => part
      }
    ]

    {events, sequence + 4}
  end

  defp generic_content_part_events(part, item_id, output_index, content_index, sequence) do
    events = [
      %{
        "type" => "response.content_part.added",
        "sequence_number" => sequence,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        "part" => part
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => sequence + 1,
        "item_id" => item_id,
        "output_index" => output_index,
        "content_index" => content_index,
        "part" => part
      }
    ]

    {events, sequence + 2}
  end
end
