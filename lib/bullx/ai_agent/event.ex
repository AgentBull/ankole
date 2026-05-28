defmodule BullX.AIAgent.Event do
  @moduledoc false

  @spec type(map()) :: String.t() | nil
  def type(event), do: value(event, "type")

  @spec id(map()) :: String.t() | nil
  def id(event), do: value(event, "id")

  @spec source(map()) :: String.t() | nil
  def source(event), do: value(event, "source")

  @spec data(map()) :: map()
  def data(event) do
    case value(event, "data") do
      %{} = data -> data
      _other -> %{}
    end
  end

  @spec text_content(map()) :: String.t()
  def text_content(data) when is_map(data) do
    data
    |> transcript_texts()
    |> Enum.join("\n")
  end

  @spec transcript_texts(map()) :: [String.t()]
  def transcript_texts(data) when is_map(data) do
    data
    |> value("content")
    |> List.wrap()
    |> Enum.flat_map(&content_part_text/1)
  end

  @spec reply_address(map()) :: map() | nil
  def reply_address(data) when is_map(data) do
    case Map.get(data, "reply_address") || Map.get(data, :reply_address) do
      %{} = reply_address -> reply_address
      _other -> nil
    end
  end

  @spec send_at(map(), DateTime.t()) :: DateTime.t()
  def send_at(data, fallback) when is_map(data) and is_struct(fallback, DateTime) do
    data
    |> get_in(["time", "send_at"])
    |> parse_datetime(fallback)
  end

  @spec trigger_principal_id(map()) :: String.t() | nil
  def trigger_principal_id(routing_context) when is_map(routing_context) do
    routing_context["triggering_principal_id"] ||
      routing_context[:triggering_principal_id] ||
      get_in(routing_context, ["actor", "principal", "id"]) ||
      get_in(routing_context, [:actor, :principal, :id]) ||
      get_in(routing_context, ["subject", "principal_id"]) ||
      get_in(routing_context, [:subject, :principal_id])
  end

  defp content_part_text(%{"type" => "text", "text" => text}), do: string_text(text)
  defp content_part_text(%{"type" => "action", "text" => text}), do: string_text(text)
  defp content_part_text(%{"fallback_text" => text}), do: string_text(text)
  defp content_part_text(%{"text" => text}), do: string_text(text)
  defp content_part_text(%{type: "text", text: text}), do: string_text(text)
  defp content_part_text(%{type: "action", text: text}), do: string_text(text)
  defp content_part_text(%{fallback_text: text}), do: string_text(text)
  defp content_part_text(%{text: text}), do: string_text(text)
  defp content_part_text(text), do: string_text(text)

  defp string_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      value -> [value]
    end
  end

  defp string_text(_text), do: []

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp parse_datetime(value, fallback) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> DateTime.truncate(fallback, :second)
    end
  end

  defp parse_datetime(_value, fallback), do: DateTime.truncate(fallback, :second)
end
