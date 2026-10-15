defmodule Ankole.AIGateway.CompactionHistory do
  alias Ankole.AIGateway.ResponseChain
  @moduledoc "Projects retained history, preserves opaque references and audits dropped items."
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionRender
  alias Ankole.AIGateway.ProviderSealedContent
  alias Ankole.AIGateway.ResponseItems

  alias Ankole.AIGateway.UpstreamCompaction
  alias Ankole.AIGateway.Schemas.Message

  @opaque_ref_keys ~w(agent_computer_path blob_ref content_type file_id file_url filename id image_url media_type mime_type name path provider_file_id provider_ref provider_uri storage_ref uri url)
  @max_ref_chars 512

  def dropped_opaque_messages(history, truncated_history) do
    kept_ids =
      truncated_history
      |> Enum.map(& &1.id)
      |> MapSet.new()

    history
    |> Enum.reject(&MapSet.member?(kept_ids, &1.id))
    |> Enum.flat_map(&opaque_message_audit/1)
  end

  def history_items_for_artifact(subject_uid, history) do
    history
    |> Enum.reduce_while({:ok, []}, fn
      %Message{type: "checkpoint"} = message, {:ok, chunks} ->
        case CompactionArtifacts.output_for_checkpoint(subject_uid, message) do
          {:ok, items} -> {:cont, {:ok, [retained_checkpoint_items(message, items) | chunks]}}
          {:error, _reason} = error -> {:halt, error}
        end

      %Message{content: content} = message, {:ok, chunks} when is_list(content) ->
        {:cont, {:ok, [message_items(message) | chunks]}}

      %Message{}, {:ok, chunks} ->
        {:cont, {:ok, chunks}}
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp retained_checkpoint_items(
         %Message{metadata: %{"strategy" => "stable_tail"}},
         [%{"type" => "compaction", "created_by" => "ankole-aigateway"} | items]
       ),
       do: items

  defp retained_checkpoint_items(_message, items), do: items

  defp opaque_message_audit(%Message{content: content} = message) when is_list(content) do
    items = opaque_item_audit(content)

    case items do
      [] ->
        []

      _nonempty ->
        [
          %{
            "message_id" => message.id,
            "response_id" => "resp_#{message.id}",
            "item_count" => length(items),
            "items" => items
          }
        ]
    end
  end

  defp opaque_message_audit(_message), do: []

  defp opaque_item_audit(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> opaque_item_audit(item, index) end)
  end

  defp opaque_item_audit(%{"type" => "message", "content" => content} = item, item_index)
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reject(fn {part, _part_index} -> text_content_part?(part) end)
    |> Enum.map(fn {part, part_index} ->
      opaque_ref(part, item_index, part_index)
      |> Ankole.Attrs.put_present("role", item["role"])
    end)
  end

  defp opaque_item_audit(%{} = item, item_index) do
    if text_compactable_item?(item) do
      []
    else
      [opaque_ref(item, item_index, nil)]
    end
  end

  defp opaque_item_audit(_item, _item_index), do: []

  defp opaque_ref(%{} = value, item_index, part_index) do
    refs = bounded_refs(value)

    %{
      "item_index" => item_index,
      "type" => Map.get(value, "type", "unknown")
    }
    |> Ankole.Attrs.put_present("part_index", part_index)
    |> put_nonempty("refs", refs)
    |> maybe_mark_missing_ref(refs)
  end

  defp bounded_refs(value) do
    value
    |> Map.take(@opaque_ref_keys)
    |> Enum.map(fn {key, ref_value} -> {key, bounded_ref_value(ref_value)} end)
    |> Enum.reject(fn {_key, ref_value} -> is_nil(ref_value) or ref_value == "" end)
    |> Map.new()
  end

  defp bounded_ref_value(value) when is_binary(value) do
    if String.length(value) > @max_ref_chars do
      String.slice(value, 0, @max_ref_chars) <> "...[truncated]"
    else
      value
    end
  end

  defp bounded_ref_value(value) when is_number(value) or is_boolean(value), do: value
  defp bounded_ref_value(_value), do: nil

  defp text_content_part?(%{"type" => type})
       when type in ["input_text", "output_text", "text"],
       do: true

  defp text_content_part?(%{"text" => text}) when is_binary(text), do: true
  defp text_content_part?(_part), do: false

  def put_nonempty(map, _key, []), do: map
  def put_nonempty(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  def put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp maybe_mark_missing_ref(map, refs) when refs == %{},
    do: Map.put(map, "missing_durable_ref", true)

  defp maybe_mark_missing_ref(map, _refs), do: map

  def truncate_history_to_stable_tail(history, current_input) do
    {checkpoint, tail} = split_last_compaction(history)
    tail_count = length(tail)
    minimum_count = min(Ankole.AIGateway.CompactionPolicy.tail_rows(), tail_count)
    boundary_plan = Ankole.AIGateway.CompactionCandidate.boundary_plan(tail, current_input)

    case Enum.find(Range.new(minimum_count, tail_count), fn retained_count ->
           prefix_count = tail_count - retained_count
           Ankole.AIGateway.CompactionCandidate.safe_boundary?(boundary_plan, prefix_count)
         end) do
      nil -> {:error, :no_safe_truncation_boundary}
      retained_count -> {:ok, checkpoint ++ Enum.take(tail, -retained_count)}
    end
  end

  def history_usage_tokens(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(0, fn
      %Message{} = message ->
        case message_usage_tokens(message) do
          tokens when tokens > 0 -> tokens
          _missing -> nil
        end

      _message ->
        nil
    end)
  end

  defp message_usage_tokens(%Message{metadata: %{} = metadata}) do
    metadata
    |> Map.get("usage")
    |> usage_tokens()
  end

  defp message_usage_tokens(_message), do: 0

  defp usage_tokens(%{} = usage) do
    total_tokens = usage_integer(usage, ["total_tokens", "totalTokens"])

    if total_tokens > 0 do
      total_tokens
    else
      usage_integer(usage, ["input_tokens", "prompt_tokens", "inputTokens"]) +
        usage_integer(usage, ["output_tokens", "completion_tokens", "outputTokens"])
    end
  end

  defp usage_tokens(_usage), do: 0

  defp usage_integer(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> false
      end
    end)
  end

  def items_token_estimate(items) do
    items
    |> Ankole.JSON.encode!()
    |> CompactionRender.approx_tokens()
  end

  def text_compactable_message?(%Message{type: "message", status: "complete", content: content})
      when is_list(content),
      do: Enum.all?(content, &text_compactable_item?/1)

  def text_compactable_message?(_message), do: false

  defp text_compactable_item?(%{"type" => "message", "content" => content}),
    do: text_compactable_content?(content)

  defp text_compactable_item?(%{"role" => role, "content" => content}) when is_binary(role),
    do: text_compactable_content?(content)

  defp text_compactable_item?(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"] and is_binary(text),
       do: true

  defp text_compactable_item?(%{"type" => "reasoning"}), do: true

  defp text_compactable_item?(item),
    do: ResponseItems.call_item?(item) or ResponseItems.output_item?(item)

  defp text_compactable_content?(content) when is_binary(content), do: true

  defp text_compactable_content?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => type} when type in ["input_text", "output_text", "text"] -> true
      %{"text" => text} when is_binary(text) -> true
      _part -> false
    end)
  end

  defp text_compactable_content?(_content), do: false

  def messages_to_items(messages) do
    Enum.flat_map(messages, &message_items/1)
  end

  def provider_neutral_tail_items(messages) do
    messages
    |> messages_to_items()
    |> Enum.flat_map(&provider_neutral_item/1)
  end

  defp provider_neutral_item(%{"type" => "reasoning"} = item) do
    item
    |> Map.delete("id")
    |> ProviderSealedContent.strip()
    |> CompactionRender.item_text()
    |> provider_neutral_text_item()
  end

  defp provider_neutral_item(%{"type" => "encrypted_content"}), do: []

  defp provider_neutral_item(%{} = item) do
    cond do
      ResponseItems.provider_replay_id_required?(item) and
          Map.get(item, "type") == "message" ->
        item
        |> Map.delete("id")
        |> ProviderSealedContent.strip()
        |> list_if_nonempty_map()

      ResponseItems.provider_replay_id_required?(item) ->
        item
        |> Map.delete("id")
        |> ProviderSealedContent.strip()
        |> CompactionRender.item_text()
        |> provider_neutral_text_item()

      true ->
        item
        |> Map.delete("id")
        |> ProviderSealedContent.strip()
        |> list_if_nonempty_map()
    end
  end

  defp provider_neutral_item(_item), do: []

  defp provider_neutral_text_item(""), do: []

  defp provider_neutral_text_item(text) when is_binary(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp list_if_nonempty_map(%{} = item) when map_size(item) > 0, do: [item]
  defp list_if_nonempty_map(_item), do: []

  def message_items(%Message{content: content}) when is_list(content), do: content

  def message_items(_message), do: []

  def input_items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  def input_items(_items), do: []

  def rows_after_last_compaction(history) do
    {_checkpoint, rest} = split_last_compaction(history)
    rest
  end

  def previous_checkpoint_items(subject_uid, history) do
    {checkpoint, _rest} = split_last_compaction(history)
    history_items_for_artifact(subject_uid, checkpoint)
  end

  # The checkpoint side is a list so that a caller can prepend it without a
  # separate empty-history branch.
  defp split_last_compaction(history) do
    case history
         |> Enum.with_index()
         |> Enum.filter(fn {row, _index} -> row.type == "checkpoint" end) do
      [] ->
        {[], history}

      indexed ->
        {row, index} = List.last(indexed)
        {[row], Enum.drop(history, index + 1)}
    end
  end

  def native_checkpoint_state(subject_uid, history, runtime) do
    case Enum.find(Enum.reverse(history), &(&1.type == "checkpoint")) do
      nil ->
        {:ok, :none}

      %Message{} = checkpoint ->
        with {:ok, content} <- CompactionArtifacts.content_for_checkpoint(subject_uid, checkpoint) do
          case content do
            %{"version" => 3, "source" => "upstream", "binding" => binding}
            when is_map(binding) ->
              state =
                if UpstreamCompaction.binding_matches?(binding, runtime),
                  do: :matching,
                  else: :mismatch

              {:ok, {:native, state}}

            %{"version" => 2} ->
              {:ok, :none}

            _invalid ->
              {:error, :invalid_compaction_handle}
          end
        end
    end
  end

  def native_checkpoint?({:native, _state}), do: true
  def native_checkpoint?(_state), do: false

  def force_local_checkpoint?({:native, :mismatch}, _upstream_compaction?), do: true

  def force_local_checkpoint?({:native, :matching}, upstream_compaction?),
    do: not upstream_compaction?

  def force_local_checkpoint?(_state, _upstream_compaction?), do: false

  def local_checkpoint_history(conversation_id, history, request, {:native, _state}),
    do: raw_history(conversation_id, history, request)

  def local_checkpoint_history(_conversation_id, history, _request, _native_state), do: history

  def raw_history(conversation_id, history, request) do
    case previous_response_id_for(history, request) do
      previous_response_id when is_binary(previous_response_id) ->
        conversation_id
        |> ResponseChain.expand_history(
          previous_response_id: previous_response_id,
          stop_at_checkpoint: false
        )
        |> Enum.reject(&(&1.type == "checkpoint"))

      _no_anchor ->
        []
    end
  end

  def previous_response_id_for(history, request) do
    case Map.get(request, "previous_response_id") do
      previous_response_id when is_binary(previous_response_id) and previous_response_id != "" ->
        previous_response_id

      _missing ->
        case List.last(history) do
          %Message{id: id} -> "resp_#{id}"
          _no_history -> nil
        end
    end
  end
end
