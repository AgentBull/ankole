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

  @spec provider_ref_metadata(map()) :: map()
  def provider_ref_metadata(data) when is_map(data) do
    case source_message_ids(data) do
      [] -> %{}
      ids -> %{"provider_refs" => %{"message_ids" => ids}}
    end
  end

  @spec source_message_ids(map()) :: [String.t()]
  def source_message_ids(data) when is_map(data) do
    [
      ref_message_ids(value(data, "refs")),
      raw_ref_message_ids(value(data, "raw_ref"))
    ]
    |> List.flatten()
    |> Enum.map(&safe_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def source_message_ids(_data), do: []

  @spec send_at(map(), DateTime.t()) :: DateTime.t()
  def send_at(data, fallback) when is_map(data) and is_struct(fallback, DateTime) do
    data
    |> get_in(["time", "send_at"])
    |> parse_datetime(fallback)
  end

  @spec trigger_principal_uid(map()) :: String.t() | nil
  def trigger_principal_uid(routing_context) when is_map(routing_context) do
    routing_context["triggering_principal_uid"] ||
      routing_context[:triggering_principal_uid] ||
      get_in(routing_context, ["actor", "principal", "id"]) ||
      get_in(routing_context, [:actor, :principal, :id]) ||
      get_in(routing_context, ["subject", "principal_uid"]) ||
      get_in(routing_context, [:subject, :principal_uid])
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

  defp ref_message_ids(refs) when is_list(refs) do
    refs
    |> Enum.flat_map(fn
      %{"kind" => kind, "id" => id} when is_binary(kind) and is_binary(id) ->
        ref_message_id(kind, id)

      %{kind: kind, id: id} when is_binary(kind) and is_binary(id) ->
        ref_message_id(kind, id)

      _ref ->
        []
    end)
  end

  defp ref_message_ids(_refs), do: []

  defp ref_message_id(kind, id) do
    case String.contains?(kind, "message") do
      true -> [id]
      false -> []
    end
  end

  defp raw_ref_message_ids(%{"message_id" => message_id}), do: [message_id]
  defp raw_ref_message_ids(%{message_id: message_id}), do: [message_id]
  defp raw_ref_message_ids(_raw_ref), do: []

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(_value), do: ""

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
