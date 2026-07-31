defmodule Ankole.AIGateway.CompactionRender do
  @moduledoc """
  Prompt rendering for AIGateway compaction.
  """

  @fallback_summarizer_context_tokens 131_072
  @min_render_budget_tokens 8_000
  @item_caps_tokens %{
    function_call_output: 2_000,
    function_call_arguments: 500,
    reasoning: 500,
    message_text: 4_000
  }
  @head_ratio 0.7

  @spec fallback_summarizer_context_tokens() :: pos_integer()
  def fallback_summarizer_context_tokens, do: @fallback_summarizer_context_tokens

  @spec min_render_budget_tokens() :: pos_integer()
  def min_render_budget_tokens, do: @min_render_budget_tokens

  @spec default_caps() :: map()
  def default_caps, do: @item_caps_tokens

  @spec scaled_caps(map(), number()) :: map()
  def scaled_caps(caps, ratio) when is_map(caps) and is_number(ratio) and ratio > 0 do
    Map.new(caps, fn {key, value} -> {key, max(floor(value * ratio), 1)} end)
  end

  @spec render_items([map()], keyword()) :: binary()
  def render_items(items, opts \\ []) when is_list(items) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    budget_tokens = Keyword.get(opts, :budget_tokens)
    call_refs = call_refs(items)

    blocks =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, index} ->
        text = item_text(item, caps: caps, call_ref: call_ref(item, call_refs))

        %{
          index: index,
          item: item,
          text: item_block(index, text),
          protected?: protected_item?(item, index, length(items))
        }
      end)

    blocks
    |> apply_budget(budget_tokens)
    |> Enum.join("\n")
  end

  @spec item_text(term(), keyword()) :: binary()
  def item_text(item, opts \\ [])

  def item_text(%{"type" => "message", "role" => role, "content" => content}, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    "#{role}: #{content_text(content, cap_tokens: cap(caps, :message_text))}"
  end

  def item_text(%{"type" => "message", "content" => content}, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    content_text(content, cap_tokens: cap(caps, :message_text))
  end

  def item_text(%{"role" => role, "content" => content}, opts) when is_binary(role) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    "#{role}: #{content_text(content, cap_tokens: cap(caps, :message_text))}"
  end

  def item_text(%{"type" => "function_call", "name" => name} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"
    args = Map.get(item, "arguments") || Map.get(item, "input") || ""
    args = stringify(args) |> truncate_text(cap(caps, :function_call_arguments))

    "function_call #{name || "(unknown)"} call_ref=#{call_ref} arguments=#{args}"
  end

  def item_text(%{"type" => "function_call_output"} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"

    output =
      Map.get(item, "output") |> stringify() |> truncate_text(cap(caps, :function_call_output))

    "function_call_output call_ref=#{call_ref} output=#{output}"
  end

  def item_text(%{"type" => "custom_tool_call", "name" => name} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"

    input =
      Map.get(item, "input") |> stringify() |> truncate_text(cap(caps, :function_call_arguments))

    "custom_tool_call #{name || "(unknown)"} call_ref=#{call_ref} input=#{input}"
  end

  def item_text(%{"type" => "custom_tool_call_output"} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"

    output =
      Map.get(item, "output") |> stringify() |> truncate_text(cap(caps, :function_call_output))

    "custom_tool_call_output call_ref=#{call_ref} output=#{output}"
  end

  def item_text(%{"type" => "program"} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"

    code =
      Map.get(item, "code") |> stringify() |> truncate_text(cap(caps, :function_call_arguments))

    "program call_ref=#{call_ref} code=#{code}"
  end

  def item_text(%{"type" => "program_output"} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)
    call_ref = Keyword.get(opts, :call_ref) || "(none)"
    status = Map.get(item, "status") || "unknown"

    result =
      Map.get(item, "result") |> stringify() |> truncate_text(cap(caps, :function_call_output))

    "program_output call_ref=#{call_ref} status=#{status} result=#{result}"
  end

  def item_text(%{"type" => "reasoning"} = item, opts) do
    caps = Keyword.get(opts, :caps, @item_caps_tokens)

    readable =
      (reasoning_texts(item["summary"]) ++ reasoning_texts(item["content"]))
      |> Enum.join("\n")
      |> String.trim()
      |> truncate_text(cap(caps, :reasoning))

    if readable == "", do: "", else: "reasoning summary: #{readable}"
  end

  def item_text(%{"type" => type}, _opts) when is_binary(type), do: "[#{type} omitted]"
  def item_text(item, _opts) when is_map(item) and map_size(item) > 0, do: "[item omitted]"
  def item_text(_item, _opts), do: ""

  @spec content_text(term(), keyword()) :: binary()
  def content_text(content, opts \\ [])

  def content_text(content, opts) when is_binary(content) do
    truncate_text(content, Keyword.get(opts, :cap_tokens))
  end

  def content_text(content, opts) when is_list(content) do
    content
    |> Enum.map(&content_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> truncate_text(Keyword.get(opts, :cap_tokens))
  end

  def content_text(content, _opts), do: stringify(content)

  @spec content_part_text(term()) :: binary()
  def content_part_text(%{"type" => type, "text" => text})
      when type in ["input_text", "output_text", "text"] and is_binary(text),
      do: text

  def content_part_text(%{"text" => text}) when is_binary(text), do: text
  def content_part_text(%{"type" => type}) when is_binary(type), do: "[#{type} omitted]"
  def content_part_text(part) when is_map(part) and map_size(part) > 0, do: "[content omitted]"
  def content_part_text(_part), do: ""

  @spec truncate_text(binary(), pos_integer() | nil) :: binary()
  def truncate_text(text, nil) when is_binary(text), do: text

  def truncate_text(text, cap_tokens)
      when is_binary(text) and is_integer(cap_tokens) and cap_tokens > 0 do
    cap_chars = cap_tokens * 4

    if String.length(text) <= cap_chars do
      text
    else
      keep_head = floor(cap_chars * @head_ratio)
      keep_tail = max(cap_chars - keep_head, 0)
      removed_chars = max(String.length(text) - keep_head - keep_tail, 0)
      removed = text |> String.slice(keep_head, removed_chars) |> approx_tokens()

      String.slice(text, 0, keep_head) <>
        "...[#{removed} tokens elided]..." <> String.slice(text, -keep_tail, keep_tail)
    end
  end

  @spec approx_tokens(binary()) :: non_neg_integer()
  def approx_tokens(""), do: 0
  def approx_tokens(text) when is_binary(text), do: max(div(byte_size(text), 4), 1)

  @spec stringify(term()) :: binary()
  def stringify(value) when is_binary(value), do: value
  def stringify(nil), do: ""
  def stringify(value), do: Ankole.JSON.encode!(value)

  defp item_block(index, text) do
    """
    <item index="#{index}">
    #{text}
    </item>
    """
  end

  defp apply_budget(blocks, nil), do: Enum.map(blocks, & &1.text)

  defp apply_budget(blocks, budget_tokens) when is_integer(budget_tokens) and budget_tokens > 0 do
    if approx_tokens(render_blocks(blocks, MapSet.new())) <= budget_tokens do
      Enum.map(blocks, & &1.text)
    else
      blocks
      |> Enum.reject(& &1.protected?)
      |> Enum.reduce_while(MapSet.new(), fn block, omitted ->
        omitted = MapSet.put(omitted, block.index)
        rendered = render_blocks(blocks, omitted)

        if approx_tokens(rendered) <= budget_tokens do
          {:halt, omitted}
        else
          {:cont, omitted}
        end
      end)
      |> then(&final_blocks(blocks, &1))
    end
  end

  defp apply_budget(blocks, _budget_tokens), do: Enum.map(blocks, & &1.text)

  defp render_blocks(blocks, omitted) do
    blocks
    |> final_blocks(omitted)
    |> Enum.join("\n")
  end

  defp final_blocks(blocks, omitted) do
    {parts, elided_count} =
      Enum.reduce(blocks, {[], 0}, fn block, {parts, elided_count} ->
        if MapSet.member?(omitted, block.index) do
          {parts, elided_count + 1}
        else
          parts = flush_elision(parts, elided_count)
          {[block.text | parts], 0}
        end
      end)

    parts
    |> flush_elision(elided_count)
    |> Enum.reverse()
  end

  defp flush_elision(parts, 0), do: parts
  defp flush_elision(parts, count), do: ["...[#{count} older items elided]..." | parts]

  defp protected_item?(item, index, total) do
    latest_start = total - ceil(total / 4) + 1
    index >= latest_start or user_message_item?(item)
  end

  defp user_message_item?(%{"role" => "user", "type" => type}) when type in [nil, "message"],
    do: true

  defp user_message_item?(%{"role" => "user"} = item),
    do: Map.get(item, "type") in [nil, "message"]

  defp user_message_item?(_item), do: false

  defp cap(caps, key), do: Map.get(caps, key) || Map.get(caps, Atom.to_string(key))

  defp call_refs(items) do
    Enum.reduce(items, %{}, fn item, refs ->
      case item do
        %{"call_id" => call_id} when is_binary(call_id) and call_id != "" ->
          Map.put_new_lazy(refs, call_id, fn -> "call_#{map_size(refs) + 1}" end)

        _item ->
          refs
      end
    end)
  end

  defp call_ref(%{"call_id" => call_id}, refs) when is_binary(call_id),
    do: Map.get(refs, call_id)

  defp call_ref(_item, _refs), do: nil

  defp reasoning_texts(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{"text" => text} when is_binary(text) -> [text]
      _item -> []
    end)
  end

  defp reasoning_texts(_items), do: []
end
