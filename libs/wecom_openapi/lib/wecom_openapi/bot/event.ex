defmodule WeComOpenAPI.Bot.Event do
  @moduledoc """
  Normalized bot channel frame delivered to dispatcher handlers.

  A push frame is `{"cmd", "headers" => {"req_id"}, "body"}` where `cmd` is
  `"aibot_msg_callback"` (messages) or `"aibot_event_callback"` (events) and
  `body` is already a JSON object. This struct surfaces the routing fields —
  `req_id` doubles as the reply anchor for `aibot_respond_msg` — so handlers
  never re-parse the envelope.
  """

  defstruct [
    :cmd,
    :req_id,
    :msgid,
    :msgtype,
    :event_type,
    :body,
    :raw
  ]

  @type t :: %__MODULE__{
          cmd: String.t() | nil,
          req_id: String.t() | nil,
          msgid: String.t() | nil,
          msgtype: String.t() | nil,
          event_type: String.t() | nil,
          body: map(),
          raw: map()
        }

  @doc "Build a normalized event from a decoded push frame."
  @spec from_frame(map()) :: t()
  def from_frame(frame) when is_map(frame) do
    headers = Map.get(frame, "headers") || %{}
    body = as_map(Map.get(frame, "body"))

    %__MODULE__{
      cmd: Map.get(frame, "cmd"),
      req_id: Map.get(headers, "req_id"),
      msgid: Map.get(body, "msgid"),
      msgtype: Map.get(body, "msgtype"),
      event_type: get_in(body, ["event", "eventtype"]),
      body: body,
      raw: frame
    }
  end

  defp as_map(body) when is_map(body), do: body
  defp as_map(_body), do: %{}
end
