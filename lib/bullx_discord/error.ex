defmodule BullXDiscord.Error do
  @moduledoc """
  Maps Discord/Nostrum failures into Gateway adapter error maps.
  """

  alias BullXGateway.AdapterError

  @spec map(term()) :: map()
  def map(%Nostrum.Error.ApiError{} = error) do
    error
    |> kind()
    |> build(error)
  end

  def map(%{"kind" => kind} = error) when is_binary(kind), do: AdapterError.stringify(error)
  def map({:payload, message}), do: payload(message)
  def map({:unsupported, message}), do: unsupported(message)
  def map({:stream_cancelled, message}), do: AdapterError.new("stream_cancelled", message)
  def map(%Jason.DecodeError{} = error), do: payload(Exception.message(error))

  def map(%Req.TransportError{} = error),
    do: AdapterError.new("network", Exception.message(error))

  def map(%Req.Response{status: status} = response), do: http_error(status, response.body)

  def map(reason),
    do: AdapterError.new("unknown", "Discord adapter error", %{"reason" => inspect(reason)})

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: AdapterError.new("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: AdapterError.new("unsupported", message, details)

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%Nostrum.Error.ApiError{status_code: 404}), do: true
  def reply_target_missing?(_error), do: false

  defp http_error(status, body) when status in [401, 403] do
    AdapterError.new("auth", "Discord API authentication failed", %{
      "status" => status,
      "body" => body
    })
  end

  defp http_error(429, body) do
    AdapterError.new("rate_limit", "Discord API rate limited", %{"status" => 429, "body" => body})
  end

  defp http_error(status, body) when status >= 500 do
    AdapterError.new("network", "Discord API server error", %{"status" => status, "body" => body})
  end

  defp http_error(status, body) do
    AdapterError.new("unknown", "Discord API error", %{"status" => status, "body" => body})
  end

  defp kind(%Nostrum.Error.ApiError{status_code: 429}), do: "rate_limit"
  defp kind(%Nostrum.Error.ApiError{status_code: status}) when status in [401, 403], do: "auth"
  defp kind(%Nostrum.Error.ApiError{status_code: status}) when status >= 500, do: "network"
  defp kind(%Nostrum.Error.ApiError{status_code: 400}), do: "payload"
  defp kind(%Nostrum.Error.ApiError{}), do: "unknown"

  defp build("rate_limit", %Nostrum.Error.ApiError{} = error) do
    AdapterError.new("rate_limit", "Discord API rate limited", details(error))
  end

  defp build("auth", %Nostrum.Error.ApiError{} = error) do
    AdapterError.new("auth", "Discord API authentication failed", details(error))
  end

  defp build("network", %Nostrum.Error.ApiError{} = error) do
    AdapterError.new("network", "Discord API transport failed", details(error))
  end

  defp build(kind, %Nostrum.Error.ApiError{} = error) do
    AdapterError.new(kind, discord_message(error), details(error))
  end

  defp details(%Nostrum.Error.ApiError{} = error) do
    %{}
    |> AdapterError.put_present("http_status", error.status_code)
    |> AdapterError.put_present("discord_code", discord_code(error))
  end

  defp discord_code(%Nostrum.Error.ApiError{response: %{code: code}}), do: code
  defp discord_code(_error), do: nil

  defp discord_message(%Nostrum.Error.ApiError{response: %{message: message}})
       when is_binary(message),
       do: message

  defp discord_message(%Nostrum.Error.ApiError{} = error), do: Exception.message(error)
end
