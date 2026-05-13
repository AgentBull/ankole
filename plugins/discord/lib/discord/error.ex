defmodule Discord.Error do
  @moduledoc """
  Maps Nostrum, Discord HTTP, and `Req` failures into Gateway adapter error
  maps. Returned shapes are JSON-neutral and string-keyed so they survive
  Gateway carrier round-trips.
  """

  @missing_target_codes [10003, 10004, 10008, 10062]

  @spec map(term()) :: map()
  def map(%{__exception__: true, __struct__: Nostrum.Error.ApiError} = error) do
    status = field(error, :status_code)
    response = field(error, :response) || %{}
    code = field(response, :code) || field(response, "code")
    message = field(response, :message) || field(response, "message")

    kind = classify_api_error(status, code)
    summary = api_summary(kind, message)

    error(
      kind,
      summary,
      %{}
      |> maybe_put("http_status", status)
      |> maybe_put("discord_code", code)
    )
  end

  def map(%{__struct__: Req.TransportError} = error) do
    error("network", "Discord transport failed", %{"reason" => exception_message(error)})
  end

  def map(%{__struct__: Req.HTTPError} = error) do
    error("network", "Discord HTTP error", %{"reason" => exception_message(error)})
  end

  def map(%{__struct__: Req.Response, status: status, body: body}) do
    error(http_kind(status), "Discord HTTP error", http_details(status, body))
  end

  def map(%{__struct__: Jason.DecodeError} = error) do
    payload("Discord response decode failed: " <> exception_message(error))
  end

  def map({:http_error, %{status: status} = response}) when is_integer(status) do
    error(
      http_kind(status),
      "Discord HTTP error #{status}",
      http_details(status, response_body(response))
    )
  end

  def map(:timeout), do: error("network", "Discord request timeout", %{})
  def map(:closed), do: error("network", "Discord connection closed", %{})

  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)

  def map({:error, reason}), do: map(reason)

  def map({kind, reason}) when is_atom(kind),
    do: error("unknown", "Discord adapter error", %{"reason" => inspect_safe({kind, reason})})

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
    do: error("ignored", "Discord event ignored", %{"reason" => to_string(reason)})

  @spec unknown(String.t()) :: map()
  def unknown(message), do: error("unknown", message, %{})

  @doc """
  Returns true when an error indicates the reply target (`message_reference`)
  is no longer reachable, so the caller may retry without it.
  """
  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%{__struct__: Nostrum.Error.ApiError} = error) do
    status = field(error, :status_code)
    response = field(error, :response) || %{}
    code = field(response, :code) || field(response, "code")
    status == 404 or code in @missing_target_codes
  end

  def reply_target_missing?({:error, reason}), do: reply_target_missing?(reason)
  def reply_target_missing?(%{"discord_code" => code}), do: code in @missing_target_codes
  def reply_target_missing?(_other), do: false

  @doc """
  Returns true when an edit/update target reports "nothing to change", which
  Discord treats as a no-op rather than a real failure.
  """
  @spec not_modified?(term()) :: boolean()
  def not_modified?(%{__struct__: Nostrum.Error.ApiError} = error) do
    response = field(error, :response) || %{}
    message = field(response, :message) || field(response, "message") || ""
    is_binary(message) and String.contains?(String.downcase(message), "is not modified")
  end

  def not_modified?({:error, reason}), do: not_modified?(reason)
  def not_modified?(_other), do: false

  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(%{__struct__: Nostrum.Error.ApiError} = error) do
    response = field(error, :response) || %{}

    case field(response, :retry_after) || field(response, "retry_after") do
      seconds when is_number(seconds) and seconds >= 0 -> trunc(seconds * 1000)
      _other -> nil
    end
  end

  def retry_after_ms({:error, reason}), do: retry_after_ms(reason)
  def retry_after_ms(_other), do: nil

  defp classify_api_error(401, _code), do: "auth"
  defp classify_api_error(403, _code), do: "permission"
  defp classify_api_error(404, _code), do: "payload"
  defp classify_api_error(429, _code), do: "rate_limit"
  defp classify_api_error(400, _code), do: "payload"

  defp classify_api_error(status, _code) when is_integer(status) and status >= 500,
    do: "provider_unavailable"

  defp classify_api_error(_status, _code), do: "unknown"

  defp api_summary("auth", _message), do: "Discord API authentication failed"
  defp api_summary("permission", _message), do: "Discord API permission denied"
  defp api_summary("rate_limit", _message), do: "Discord API rate limited"
  defp api_summary("provider_unavailable", _message), do: "Discord API server error"
  defp api_summary(_kind, message) when is_binary(message) and message != "", do: message
  defp api_summary(_kind, _message), do: "Discord API error"

  defp http_kind(429), do: "rate_limit"
  defp http_kind(status) when status in [401, 403], do: "auth"
  defp http_kind(status) when is_integer(status) and status >= 500, do: "provider_unavailable"
  defp http_kind(_status), do: "unknown"

  defp http_details(status, body) do
    %{}
    |> maybe_put("http_status", status)
    |> maybe_put("body", body_summary(body))
  end

  defp body_summary(body) when is_map(body), do: body
  defp body_summary(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp body_summary(_body), do: nil

  defp response_body(%{body: body}), do: body
  defp response_body(_response), do: nil

  defp exception_message(%{__exception__: true} = error) do
    case Exception.message(error) do
      message when is_binary(message) -> String.slice(message, 0, 200)
      _other -> inspect_safe(error)
    end
  end

  defp exception_message(other), do: inspect_safe(other)

  defp error(kind, message, details) do
    %{
      "kind" => kind,
      "message" => safe_message(message),
      "details" => safe_details(details)
    }
  end

  defp stringify(%{} = error) do
    error
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("details", %{})
  end

  defp safe_message(message) when is_binary(message), do: message
  defp safe_message(other), do: inspect_safe(other)

  defp safe_details(details) when is_map(details) do
    details
    |> Map.new(fn {key, value} -> {to_string(key), json_scalar(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_details(_details), do: %{}

  defp json_scalar(value) when is_binary(value), do: value
  defp json_scalar(value) when is_integer(value), do: value
  defp json_scalar(value) when is_boolean(value), do: value
  defp json_scalar(%{} = value), do: value
  defp json_scalar(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_scalar(nil), do: nil
  defp json_scalar(_value), do: nil

  defp inspect_safe(value), do: value |> inspect() |> String.slice(0, 200)

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
