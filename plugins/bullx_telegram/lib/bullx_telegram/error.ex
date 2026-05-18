defmodule BullxTelegram.Error do
  @moduledoc false

  @permission_descriptions [
    "forbidden",
    "bot was kicked",
    "bot can't",
    "not enough rights",
    "blocked by the user",
    "bot was blocked"
  ]
  @reply_target_descriptions [
    "replied message not found",
    "message to reply not found",
    "message_id_invalid",
    "reply_to message not found",
    "message_reply_info_empty"
  ]

  @spec map(term()) :: map()
  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)
  def map({:error, reason}), do: map(reason)
  def map(:timeout), do: error("network", "Telegram request timeout", %{})
  def map(:closed), do: error("network", "Telegram connection closed", %{})
  def map(%{__struct__: Req.TransportError} = error), do: error("network", "Telegram transport failed", exception_details(error))
  def map(%{__struct__: Req.HTTPError} = error), do: error("network", "Telegram HTTP error", exception_details(error))

  def map(%{__struct__: Req.Response, status: status, body: body}) when is_integer(status) do
    error(http_kind(status, body), "Telegram HTTP error #{status}", api_details(body) |> Map.put("http_status", status))
  end

  def map(%{"ok" => false} = response), do: error(api_kind(response), Map.get(response, "description", "Telegram API error"), api_details(response))
  def map(%{"description" => description} = response) when is_binary(description), do: error(api_kind(response), description, api_details(response))
  def map({:http_error, %{status: status, body: body}}), do: error(http_kind(status, body), "Telegram HTTP error #{status}", api_details(body) |> Map.put("http_status", status))
  def map(reason), do: unknown(inspect_safe(reason))

  @spec config(String.t(), map()) :: map()
  def config(message, details \\ %{}), do: error("config", message, details)

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: error("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: error("unsupported", message, details)

  @spec auth(String.t(), map()) :: map()
  def auth(message, details \\ %{}), do: error("auth", message, details)

  @spec unknown(String.t()) :: map()
  def unknown(message), do: error("unknown", message, %{})

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?({:error, reason}), do: reply_target_missing?(reason)
  def reply_target_missing?(%{"details" => details}) when is_map(details), do: reply_target_missing?(details)

  def reply_target_missing?(%{"description" => description}) when is_binary(description) do
    lower = String.downcase(description)
    Enum.any?(@reply_target_descriptions, &String.contains?(lower, &1))
  end

  def reply_target_missing?(_other), do: false

  @spec not_modified?(term()) :: boolean()
  def not_modified?({:error, reason}), do: not_modified?(reason)

  def not_modified?(%{"description" => description}) when is_binary(description) do
    description |> String.downcase() |> String.contains?("is not modified")
  end

  def not_modified?(_other), do: false

  @spec polling_conflict?(term()) :: boolean()
  def polling_conflict?({:error, reason}), do: polling_conflict?(reason)
  def polling_conflict?(%{"error_code" => 409}), do: true

  def polling_conflict?(%{"description" => description}) when is_binary(description) do
    description |> String.downcase() |> String.contains?("terminated by other")
  end

  def polling_conflict?(_other), do: false

  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms({:error, reason}), do: retry_after_ms(reason)
  def retry_after_ms(%{"parameters" => %{"retry_after" => seconds}}) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  def retry_after_ms(%{"retry_after" => seconds}) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  def retry_after_ms(_other), do: nil

  defp http_kind(429, _body), do: "rate_limit"
  defp http_kind(status, _body) when status in [401, 403], do: "auth"
  defp http_kind(409, body), do: if(polling_conflict?(body), do: "polling_conflict", else: "unknown")
  defp http_kind(status, _body) when status >= 500, do: "provider_unavailable"
  defp http_kind(_status, _body), do: "unknown"

  defp api_kind(%{"error_code" => 401}), do: "auth"
  defp api_kind(%{"error_code" => 403} = response), do: permission_or_auth(response)
  defp api_kind(%{"error_code" => 409}), do: "polling_conflict"
  defp api_kind(%{"error_code" => 429}), do: "rate_limit"
  defp api_kind(%{"parameters" => %{"retry_after" => _}}), do: "rate_limit"

  defp api_kind(%{"description" => description}) when is_binary(description) do
    lower = String.downcase(description)

    cond do
      String.contains?(lower, "too many requests") -> "rate_limit"
      String.contains?(lower, "unauthorized") -> "auth"
      Enum.any?(@reply_target_descriptions, &String.contains?(lower, &1)) -> "payload"
      Enum.any?(@permission_descriptions, &String.contains?(lower, &1)) -> "permission"
      true -> "unknown"
    end
  end

  defp api_kind(_response), do: "unknown"

  defp permission_or_auth(%{"description" => description}) when is_binary(description) do
    lower = String.downcase(description)
    if Enum.any?(@permission_descriptions, &String.contains?(lower, &1)), do: "permission", else: "auth"
  end

  defp permission_or_auth(_response), do: "auth"

  defp api_details(%{} = response) do
    %{}
    |> maybe_put("error_code", Map.get(response, "error_code"))
    |> maybe_put("description", Map.get(response, "description"))
    |> maybe_put("retry_after", retry_after_seconds(response))
  end

  defp api_details(_response), do: %{}
  defp retry_after_seconds(%{"parameters" => %{"retry_after" => seconds}}) when is_integer(seconds), do: seconds
  defp retry_after_seconds(%{"retry_after" => seconds}) when is_integer(seconds), do: seconds
  defp retry_after_seconds(_response), do: nil

  defp error(kind, message, details), do: %{"kind" => kind, "message" => safe_message(message), "details" => safe_details(details)}
  defp stringify(%{} = error), do: error |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.put_new("details", %{})
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
  defp json_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_value(_value), do: nil
  defp inspect_safe(value), do: value |> inspect() |> String.slice(0, 200)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
