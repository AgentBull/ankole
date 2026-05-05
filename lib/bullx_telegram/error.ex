defmodule BullXTelegram.Error do
  @moduledoc """
  Maps Telegram API and adapter failures into Gateway adapter error maps.
  """

  @spec map(term()) :: map()
  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)

  def map(%{"description" => description} = error) when is_binary(description),
    do: telegram_description(description, error)

  def map({:payload, message}), do: payload(message)
  def map({:unsupported, message}), do: unsupported(message)
  def map(%Jason.DecodeError{} = error), do: payload(Exception.message(error))
  def map(%Req.TransportError{} = error), do: base("network", Exception.message(error), %{})
  def map({:http_error, status}), do: http_error(status, nil)
  def map({kind, reason}) when kind in [:throw, :exit, :error], do: unknown({kind, reason})
  def map(reason) when is_binary(reason), do: telegram_description(reason)
  def map(reason), do: unknown(reason)

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: base("payload", message, details)

  @spec config(String.t(), map()) :: map()
  def config(message, details \\ %{}), do: base("config", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: base("unsupported", message, details)

  @spec polling_conflict?(term()) :: boolean()
  def polling_conflict?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.contains?("conflict")
  end

  def polling_conflict?(reason), do: polling_conflict?(inspect(reason))

  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(%{"details" => details}) when is_map(details),
    do: retry_after_ms_from(details)

  def retry_after_ms(%{details: details}) when is_map(details),
    do: retry_after_ms_from(details)

  def retry_after_ms(reason), do: retry_after_ms_from(reason)

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(reason) when is_binary(reason) do
    text = String.downcase(reason)

    String.contains?(text, "message to be replied") or
      String.contains?(text, "reply message not found")
  end

  def reply_target_missing?(_reason), do: false

  @spec not_modified?(term()) :: boolean()
  def not_modified?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.contains?("message is not modified")
  end

  def not_modified?(_reason), do: false

  defp telegram_description(description), do: telegram_description(description, description)

  defp telegram_description(description, retry_source) do
    text = String.downcase(description)

    cond do
      String.contains?(text, "unauthorized") or String.contains?(text, "forbidden") ->
        base("auth", "Telegram API authentication failed", %{})

      String.contains?(text, "too many requests") ->
        base("rate_limited", "Telegram API rate limited", retry_after_details(retry_source))

      polling_conflict?(description) ->
        base("network", "Telegram polling conflict", %{"telegram_description" => description})

      true ->
        base("unknown", "Telegram API error", %{"telegram_description" => description})
    end
  end

  defp http_error(status, body) when status in [401, 403] do
    base("auth", "Telegram API authentication failed", %{"status" => status, "body" => body})
  end

  defp http_error(429, body) do
    base(
      "rate_limited",
      "Telegram API rate limited",
      Map.merge(%{"status" => 429, "body" => body}, retry_after_details(body))
    )
  end

  defp http_error(status, body) when is_integer(status) and status >= 500 do
    base("network", "Telegram API server error", %{"status" => status, "body" => body})
  end

  defp http_error(status, body) do
    base("unknown", "Telegram API error", %{"status" => status, "body" => body})
  end

  defp unknown(reason),
    do: base("unknown", "Telegram adapter error", %{"reason" => inspect(reason)})

  defp base(kind, message, details) do
    %{"kind" => kind, "message" => message, "details" => stringify(details)}
  end

  defp retry_after_details(reason) do
    case retry_after_ms_from(reason) do
      milliseconds when is_integer(milliseconds) -> %{"retry_after_ms" => milliseconds}
      nil -> %{}
    end
  end

  defp retry_after_ms_from(%{"retry_after_ms" => milliseconds}),
    do: non_negative_integer(milliseconds)

  defp retry_after_ms_from(%{retry_after_ms: milliseconds}),
    do: non_negative_integer(milliseconds)

  defp retry_after_ms_from(%{"retry_after" => seconds}), do: seconds_to_ms(seconds)
  defp retry_after_ms_from(%{retry_after: seconds}), do: seconds_to_ms(seconds)

  defp retry_after_ms_from(%{"parameters" => parameters}) when is_map(parameters),
    do: retry_after_ms_from(parameters)

  defp retry_after_ms_from(%{parameters: parameters}) when is_map(parameters),
    do: retry_after_ms_from(parameters)

  defp retry_after_ms_from(description) when is_binary(description) do
    case Regex.run(~r/retry after\s+(\d+)/i, description) do
      [_match, seconds] -> seconds_to_ms(seconds)
      _other -> nil
    end
  end

  defp retry_after_ms_from(_reason), do: nil

  defp seconds_to_ms(seconds) do
    case non_negative_integer(seconds) do
      seconds when is_integer(seconds) -> seconds * 1_000
      nil -> nil
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
