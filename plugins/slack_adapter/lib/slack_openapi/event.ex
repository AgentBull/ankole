defmodule SlackOpenAPI.Event do
  @moduledoc "Normalized Socket Mode event delivered to handlers."

  defstruct [
    :id,
    :type,
    :content,
    :created_at,
    :team_id,
    :api_app_id,
    :retry_attempt,
    :retry_reason,
    :raw
  ]

  @type t :: %__MODULE__{}

  @spec from_envelope(map()) :: t()
  def from_envelope(%{"type" => "events_api", "payload" => payload} = envelope) do
    content = Map.get(payload, "event", %{})

    %__MODULE__{
      id: Map.get(payload, "event_id") || Map.get(envelope, "envelope_id"),
      type: Map.get(content, "type"),
      content: content,
      created_at: unix_datetime(Map.get(payload, "event_time")),
      team_id: Map.get(payload, "team_id"),
      api_app_id: Map.get(payload, "api_app_id"),
      retry_attempt: Map.get(envelope, "retry_attempt", 0),
      retry_reason: Map.get(envelope, "retry_reason"),
      raw: envelope
    }
  end

  def from_envelope(%{"type" => "interactive", "payload" => payload} = envelope) do
    %__MODULE__{
      id: Map.get(envelope, "envelope_id"),
      type: Map.get(payload, "type"),
      content: payload,
      created_at: action_datetime(payload),
      team_id: get_in(payload, ["team", "id"]) || get_in(payload, ["user", "team_id"]),
      api_app_id: Map.get(payload, "api_app_id"),
      retry_attempt: Map.get(envelope, "retry_attempt", 0),
      retry_reason: Map.get(envelope, "retry_reason"),
      raw: envelope
    }
  end

  def from_envelope(envelope) do
    %__MODULE__{
      id: Map.get(envelope, "envelope_id"),
      type: Map.get(envelope, "type"),
      content: Map.get(envelope, "payload", %{}),
      raw: envelope
    }
  end

  defp unix_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp unix_datetime(_value), do: nil

  defp action_datetime(payload) do
    case get_in(payload, ["actions", Access.at(0), "action_ts"]) do
      value when is_binary(value) ->
        case Float.parse(value) do
          {seconds, _rest} -> DateTime.from_unix!(round(seconds * 1_000_000), :microsecond)
          :error -> nil
        end

      _value ->
        nil
    end
  end
end
