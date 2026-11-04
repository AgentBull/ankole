defmodule Ankole.Conversations.Delivery.ToolOutput do
  @moduledoc false

  alias Ankole.JSON

  def outputs(items, tool_name) when is_list(items) do
    call_ids =
      for %{"type" => "function_call", "name" => ^tool_name, "call_id" => id} <- items,
          is_binary(id),
          into: MapSet.new(),
          do: id

    Stream.flat_map(items, fn
      %{"type" => "function_call_output", "call_id" => id} = item when is_binary(id) ->
        if MapSet.member?(call_ids, id), do: [{decode(item["output"]), id}], else: []

      _item ->
        []
    end)
  end

  def outputs(_items, _tool_name), do: []

  def last(items, tool_name, normalize) do
    items
    |> outputs(tool_name)
    |> Enum.reduce_while({:ok, nil}, fn {output, call_id}, {:ok, current} ->
      case normalize.(output, call_id) do
        {:ok, normalized} -> {:cont, {:ok, normalized}}
        :ignore -> {:cont, {:ok, current}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def decode(output) when is_binary(output) do
    case output |> String.trim() |> JSON.decode() do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  def decode(output) when is_map(output), do: output
  def decode(_output), do: nil
end
