defmodule DingTalkOpenAPI.Event do
  @moduledoc """
  Normalized DingTalk Stream frame delivered to dispatcher handlers.

  A Stream push frame is `{"specVersion", "type", "headers", "data"}` where
  `type` is `"SYSTEM" | "EVENT" | "CALLBACK"`, the routing key lives in
  `headers` (`"topic"` for callbacks, `"eventType"` for events), and `data` is a
  JSON string. This struct decodes `data` once and surfaces the routing fields
  so handlers and the dispatcher never re-parse the envelope.
  """

  defstruct [
    :type,
    :topic,
    :event_type,
    :event_id,
    :message_id,
    :headers,
    :data,
    :raw
  ]

  @type t :: %__MODULE__{
          type: String.t() | nil,
          topic: String.t() | nil,
          event_type: String.t() | nil,
          event_id: String.t() | nil,
          message_id: String.t() | nil,
          headers: map(),
          data: map() | String.t() | nil,
          raw: map()
        }

  @doc "Build a normalized event from a decoded Stream frame, decoding `data`."
  @spec from_frame(map()) :: t()
  def from_frame(frame) when is_map(frame) do
    headers = Map.get(frame, "headers", %{})

    %__MODULE__{
      type: Map.get(frame, "type"),
      topic: Map.get(headers, "topic"),
      event_type: Map.get(headers, "eventType"),
      event_id: Map.get(headers, "eventId"),
      message_id: Map.get(headers, "messageId"),
      headers: headers,
      data: decode_data(Map.get(frame, "data")),
      raw: frame
    }
  end

  defp decode_data(nil), do: nil
  defp decode_data(data) when is_map(data), do: data

  defp decode_data(data) when is_binary(data) do
    case Torque.decode(data) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> data
    end
  end

  defp decode_data(data), do: data
end
