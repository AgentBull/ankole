defmodule Discord.Error do
  @moduledoc false

  import BullX.Utils.Map, only: [maybe_put: 3]

  @missing_target_codes [10_003, 10_004, 10_008, 10_062]

  @spec map(term()) :: map()
  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)
  def map({:error, reason}), do: map(reason)
  def map(:timeout), do: error("network", "Discord request timeout", %{})
  def map(:closed), do: error("network", "Discord connection closed", %{})
  def map(%{__struct__: Req.TransportError} = error), do: error("network", "Discord transport failed", exception_details(error))
  def map(%{__struct__: Req.HTTPError} = error), do: error("network", "Discord HTTP error", exception_details(error))
  def map(%{__struct__: Jason.DecodeError} = error), do: payload("Discord response decode failed", exception_details(error))

  def map(%{__struct__: Req.Response, status: status, body: body}) when is_integer(status) do
    error(http_kind(status), "Discord HTTP error #{status}", http_details(status, body))
  end

  def map({:http_error, %{status: status} = response}) when is_integer(status) do
    error(http_kind(status), "Discord HTTP error #{status}", http_details(status, response_body(response)))
  end

  def map(reason), do: unknown(inspect_safe(reason))

  @spec config(String.t(), map()) :: map()
  def config(message, details \\ %{}), do: error("config", message, details)

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: error("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: error("unsupported", message, details)

  @spec auth(String.t(), map()) :: map()
  def auth(message, details \\ %{}), do: error("auth", message, details)

  @spec principal(String.t(), map()) :: map()
  def principal(message, details \\ %{}), do: error("principal", message, details)

  @spec unknown(String.t()) :: map()
  def unknown(message), do: error("unknown", message, %{})

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?({:error, reason}), do: reply_target_missing?(reason)
  def reply_target_missing?(%{"discord_code" => code}), do: code in @missing_target_codes
  def reply_target_missing?(%{"details" => details}) when is_map(details), do: reply_target_missing?(details)
  def reply_target_missing?(%{status: 404}), do: true
  def reply_target_missing?(_other), do: false

  @spec not_modified?(term()) :: boolean()
  def not_modified?({:error, reason}), do: not_modified?(reason)

  def not_modified?(%{"message" => message}) when is_binary(message) do
    message |> String.downcase() |> String.contains?("not modified")
  end

  def not_modified?(_other), do: false

  defp http_kind(400), do: "payload"
  defp http_kind(401), do: "auth"
  defp http_kind(403), do: "permission"
  defp http_kind(404), do: "not_found"
  defp http_kind(429), do: "rate_limit"
  defp http_kind(status) when status >= 500, do: "provider_unavailable"
  defp http_kind(_status), do: "unknown"

  defp http_details(status, body) do
    %{}
    |> maybe_put("http_status", status)
    |> maybe_put("discord_code", field(body, "code"))
    |> maybe_put("message", field(body, "message"))
    |> maybe_put("retry_after_ms", retry_after_ms(body))
  end

  defp retry_after_ms(%{} = body) do
    case field(body, "retry_after") do
      seconds when is_number(seconds) and seconds >= 0 -> trunc(seconds * 1000)
      _value -> nil
    end
  end

  defp retry_after_ms(_body), do: nil
  defp response_body(%{body: body}), do: body
  defp response_body(_response), do: nil

  defp error(kind, message, details) do
    %{"kind" => kind, "message" => safe_message(message), "details" => safe_details(details)}
  end

  defp stringify(%{} = error) do
    error
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("details", %{})
  end

  defp exception_details(%{__exception__: true} = exception), do: %{"reason" => Exception.message(exception)}
  defp safe_message(message) when is_binary(message), do: message
  defp safe_message(message), do: inspect_safe(message)

  defp safe_details(%{} = details) do
    details
    |> Map.new(fn {key, value} -> {to_string(key), json_value(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_details(_details), do: %{}
  defp json_value(value) when is_binary(value) or is_integer(value) or is_boolean(value), do: value
  defp json_value(value) when is_float(value), do: value
  defp json_value(%{} = value), do: safe_details(value)
  defp json_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_value(_value), do: nil
  defp inspect_safe(value), do: value |> inspect() |> String.slice(0, 200)

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp field(_value, _key), do: nil
end
