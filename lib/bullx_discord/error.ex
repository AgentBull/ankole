defmodule BullXDiscord.Error do
  @moduledoc """
  Maps Discord/Nostrum failures into Gateway adapter error maps.
  """

  @spec map(term()) :: map()
  def map(%Nostrum.Error.ApiError{} = error) do
    error
    |> kind()
    |> build(error)
  end

  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)
  def map({:payload, message}), do: payload(message)
  def map({:unsupported, message}), do: unsupported(message)
  def map({:stream_cancelled, message}), do: base("stream_cancelled", message, %{})
  def map(%Jason.DecodeError{} = error), do: payload(Exception.message(error))
  def map(%Req.TransportError{} = error), do: base("network", Exception.message(error), %{})
  def map(%Req.Response{status: status} = response), do: http_error(status, response.body)
  def map(reason), do: base("unknown", "Discord adapter error", %{"reason" => inspect(reason)})

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: base("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: base("unsupported", message, details)

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%Nostrum.Error.ApiError{status_code: 404}), do: true
  def reply_target_missing?(_error), do: false

  defp http_error(status, body) when status in [401, 403] do
    base("auth", "Discord API authentication failed", %{"status" => status, "body" => body})
  end

  defp http_error(429, body) do
    base("rate_limit", "Discord API rate limited", %{"status" => 429, "body" => body})
  end

  defp http_error(status, body) when status >= 500 do
    base("network", "Discord API server error", %{"status" => status, "body" => body})
  end

  defp http_error(status, body) do
    base("unknown", "Discord API error", %{"status" => status, "body" => body})
  end

  defp kind(%Nostrum.Error.ApiError{status_code: 429}), do: "rate_limit"
  defp kind(%Nostrum.Error.ApiError{status_code: status}) when status in [401, 403], do: "auth"
  defp kind(%Nostrum.Error.ApiError{status_code: status}) when status >= 500, do: "network"
  defp kind(%Nostrum.Error.ApiError{status_code: 400}), do: "payload"
  defp kind(%Nostrum.Error.ApiError{}), do: "unknown"

  defp build("rate_limit", %Nostrum.Error.ApiError{} = error) do
    base("rate_limit", "Discord API rate limited", details(error))
  end

  defp build("auth", %Nostrum.Error.ApiError{} = error) do
    base("auth", "Discord API authentication failed", details(error))
  end

  defp build("network", %Nostrum.Error.ApiError{} = error) do
    base("network", "Discord API transport failed", details(error))
  end

  defp build(kind, %Nostrum.Error.ApiError{} = error) do
    base(kind, discord_message(error), details(error))
  end

  defp details(%Nostrum.Error.ApiError{} = error) do
    %{}
    |> maybe_put("http_status", error.status_code)
    |> maybe_put("discord_code", discord_code(error))
  end

  defp discord_code(%Nostrum.Error.ApiError{response: %{code: code}}), do: code
  defp discord_code(_error), do: nil

  defp discord_message(%Nostrum.Error.ApiError{response: %{message: message}})
       when is_binary(message),
       do: message

  defp discord_message(%Nostrum.Error.ApiError{} = error), do: Exception.message(error)

  defp base(kind, message, details) do
    %{"kind" => kind, "message" => message, "details" => stringify(details)}
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
