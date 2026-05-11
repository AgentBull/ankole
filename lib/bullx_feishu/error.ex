defmodule BullXFeishu.Error do
  @moduledoc """
  Maps Feishu SDK/API failures into Gateway adapter error maps.

  Gateway retry, DLQ, and operator recovery logic expects JSON-neutral maps
  with a string `kind`. This module is the single normalization boundary for
  Feishu adapter failures.
  """

  alias BullXGateway.AdapterError
  alias FeishuOpenAPI.Error, as: SDKError

  @rate_limit_codes [99_991_400]
  @auth_codes [99_991_663, 99_991_664, 99_991_671, 10_012, 514, 403, 1_000_040_350]
  @reply_missing_codes [230_011, 231_003]

  @spec map(term()) :: map()
  def map(%SDKError{} = error) do
    error
    |> kind()
    |> build(error)
  end

  def map(%{"kind" => kind} = error) when is_binary(kind), do: AdapterError.stringify(error)
  def map({:payload, message}), do: payload(message)
  def map({:unsupported, message}), do: unsupported(message)
  def map({:stream_cancelled, message}), do: AdapterError.new("stream_cancelled", message)

  def map(reason),
    do: AdapterError.new("unknown", "Feishu adapter error", %{"reason" => inspect(reason)})

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: AdapterError.new("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: AdapterError.new("unsupported", message, details)

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%SDKError{code: code}), do: code in @reply_missing_codes
  def reply_target_missing?(_), do: false

  defp kind(%SDKError{http_status: 429}), do: "rate_limit"
  defp kind(%SDKError{code: code}) when code in @rate_limit_codes, do: "rate_limit"
  defp kind(%SDKError{http_status: status}) when status in [401, 403], do: "auth"
  defp kind(%SDKError{code: code}) when code in @auth_codes, do: "auth"
  defp kind(%SDKError{code: :transport}), do: "network"
  defp kind(%SDKError{code: :rate_limited}), do: "rate_limit"

  defp kind(%SDKError{code: code}) when code in [:bad_path, :bad_file, :unexpected_shape],
    do: "payload"

  defp kind(%SDKError{}), do: "unknown"

  defp build("rate_limit", %SDKError{} = error) do
    details =
      error
      |> details()
      |> Map.put_new("retry_after_ms", retry_after_ms(error))

    AdapterError.new("rate_limit", "Feishu API rate limited", details)
  end

  defp build("auth", %SDKError{} = error),
    do: AdapterError.new("auth", "Feishu API authentication failed", details(error))

  defp build("network", %SDKError{} = error),
    do: AdapterError.new("network", "Feishu API transport failed", details(error))

  defp build("payload", %SDKError{} = error),
    do: AdapterError.new("payload", error.msg || "Invalid Feishu payload", details(error))

  defp build(kind, %SDKError{} = error),
    do: AdapterError.new(kind, error.msg || "Feishu API error", details(error))

  defp details(%SDKError{} = error) do
    %{}
    |> AdapterError.put_present("code", error.code)
    |> AdapterError.put_present("http_status", error.http_status)
    |> AdapterError.put_present("log_id", error.log_id)
  end

  defp retry_after_ms(%SDKError{details: %{"retry_after" => value}}) when is_integer(value),
    do: value

  defp retry_after_ms(_), do: 1_000
end
