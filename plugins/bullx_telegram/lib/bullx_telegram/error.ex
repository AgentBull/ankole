defmodule BullxTelegram.Error do
  @moduledoc false

  @permission_descriptions [
    "forbidden",
    "bot was kicked",
    "bot can't",
    "bot is not a member",
    "have no rights",
    "not enough rights",
    "blocked by the user",
    "bot was blocked"
  ]
  @reply_target_descriptions [
    "replied message not found",
    "message to reply not found",
    "message_id_invalid",
    "reply_to message not found",
    "reply to message not found",
    "message_reply_info_empty"
  ]
  @polling_conflict_substring "terminated by other"
  @not_modified_substring "is not modified"

  @spec map(term()) :: map()
  def map(%BullX.Gateway.OutboundError{} = error) do
    %{
      "kind" => Atom.to_string(error.class),
      "message" => error.safe_message,
      "details" => error.details
    }
  end

  def map(%{"kind" => _kind} = error), do: error
  def map({:error, reason}), do: map(reason)
  def map(:timeout), do: error("network", "Telegram request timeout", %{})
  def map(:closed), do: error("network", "Telegram connection closed", %{})

  def map({:http_error, %{status: status} = response}) when is_integer(status) do
    error(http_kind(status, response), "Telegram HTTP error #{status}", http_details(response))
  end

  def map({:http_error, reason}), do: error("network", "Telegram HTTP error", %{"reason" => inspect_safe(reason)})
  def map({:error_response, %{} = response}), do: map(response)

  def map(%{"description" => description} = response) when is_binary(description) do
    error(api_kind(response), description, api_details(response))
  end

  def map(%{"ok" => false} = response), do: map(Map.put(response, "description", "Telegram API error"))

  def map(reason), do: unknown(inspect_safe(reason))

  @spec config(String.t(), map()) :: map()
  def config(message, details \\ %{}), do: error("config", message, details)

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: error("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: error("unsupported", message, details)

  @spec auth(String.t(), map()) :: map()
  def auth(message, details \\ %{}), do: error("auth", message, details)

  @spec ignored(atom() | String.t()) :: map()
  def ignored(reason),
    do: error("ignored", "Telegram update ignored", %{"reason" => to_string(reason)})

  @spec unknown(String.t()) :: map()
  def unknown(message), do: error("unknown", message, %{})

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?({:error, reason}), do: reply_target_missing?(reason)
  def reply_target_missing?({:error_response, response}), do: reply_target_missing?(response)

  def reply_target_missing?(%{"description" => description}) when is_binary(description) do
    lower = String.downcase(description)
    Enum.any?(@reply_target_descriptions, &String.contains?(lower, &1))
  end

  def reply_target_missing?(_other), do: false

  @spec not_modified?(term()) :: boolean()
  def not_modified?({:error, reason}), do: not_modified?(reason)
  def not_modified?({:error_response, response}), do: not_modified?(response)

  def not_modified?(%{"description" => description}) when is_binary(description) do
    description |> String.downcase() |> String.contains?(@not_modified_substring)
  end

  def not_modified?(_other), do: false

  @spec polling_conflict?(term()) :: boolean()
  def polling_conflict?({:error, reason}), do: polling_conflict?(reason)
  def polling_conflict?({:error_response, response}), do: polling_conflict?(response)
  def polling_conflict?({:http_error, response}), do: polling_conflict?(response)

  def polling_conflict?(%{"error_code" => 409}), do: true

  def polling_conflict?(%{"description" => description}) when is_binary(description) do
    description |> String.downcase() |> String.contains?(@polling_conflict_substring)
  end

  def polling_conflict?(_other), do: false

  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms({:error, reason}), do: retry_after_ms(reason)
  def retry_after_ms({:error_response, response}), do: retry_after_ms(response)

  def retry_after_ms(%{"parameters" => %{"retry_after" => seconds}})
      when is_integer(seconds) and seconds >= 0 do
    seconds * 1000
  end

  def retry_after_ms(%{"retry_after" => seconds}) when is_integer(seconds) and seconds >= 0 do
    seconds * 1000
  end

  def retry_after_ms(_other), do: nil

  defp error(kind, message, details) do
    %{
      "kind" => kind,
      "message" => safe_message(message),
      "details" => safe_details(details)
    }
  end

  defp http_kind(429, _response), do: "rate_limit"
  defp http_kind(status, _response) when status in [401, 403], do: "auth"
  defp http_kind(409, response), do: if(polling_conflict?(response), do: "polling_conflict", else: "unknown")
  defp http_kind(status, _response) when status in 500..599, do: "provider_unavailable"
  defp http_kind(_status, _response), do: "unknown"

  defp api_kind(%{"error_code" => 401}), do: "auth"
  defp api_kind(%{"error_code" => 403} = response), do: permission_or_auth(response)
  defp api_kind(%{"error_code" => 409}), do: "polling_conflict"
  defp api_kind(%{"error_code" => 429}), do: "rate_limit"
  defp api_kind(%{"parameters" => %{"retry_after" => _}}), do: "rate_limit"
  defp api_kind(%{"description" => description}) when is_binary(description) do
    description |> String.downcase() |> categorize_description()
  end

  defp api_kind(_other), do: "unknown"

  defp permission_or_auth(%{"description" => description}) when is_binary(description) do
    lower = String.downcase(description)

    case Enum.any?(@permission_descriptions, &String.contains?(lower, &1)) do
      true -> "permission"
      false -> "auth"
    end
  end

  defp permission_or_auth(_other), do: "auth"

  defp categorize_description(description) do
    cond do
      String.contains?(description, "too many requests") -> "rate_limit"
      String.contains?(description, "unauthorized") -> "auth"
      Enum.any?(@reply_target_descriptions, &String.contains?(description, &1)) -> "payload"
      Enum.any?(@permission_descriptions, &String.contains?(description, &1)) -> "permission"
      true -> "unknown"
    end
  end

  defp http_details(%{status: status, body: body}) when is_map(body) do
    body
    |> api_details()
    |> Map.put("http_status", status)
  end

  defp http_details(%{status: status}), do: %{"http_status" => status}
  defp http_details(_response), do: %{}

  defp api_details(%{} = response) do
    %{}
    |> maybe_put("error_code", Map.get(response, "error_code"))
    |> maybe_put("description", Map.get(response, "description"))
    |> maybe_put("retry_after", retry_after_seconds(response))
  end

  defp api_details(_response), do: %{}

  defp retry_after_seconds(%{"parameters" => %{"retry_after" => seconds}})
       when is_integer(seconds),
       do: seconds

  defp retry_after_seconds(%{"retry_after" => seconds}) when is_integer(seconds), do: seconds
  defp retry_after_seconds(_response), do: nil

  defp safe_details(details) when is_map(details) do
    details
    |> Map.new(fn {key, value} -> {to_string(key), json_scalar(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_details(_details), do: %{}

  defp safe_message(message) when is_binary(message), do: message
  defp safe_message(message), do: inspect_safe(message)

  defp inspect_safe(value), do: value |> inspect() |> String.slice(0, 200)

  defp json_scalar(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: value

  defp json_scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp json_scalar(nil), do: nil
  defp json_scalar(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
