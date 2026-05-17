defmodule Feishu.Error do
  @moduledoc false

  alias FeishuOpenAPI.Error, as: OpenAPIError

  @rate_limit_codes [99_991_400]
  @reply_target_missing_codes [230_011, 231_003]
  @auth_codes [99_991_663, 99_991_664, 99_991_671, 10_012, 514, 403, 1_000_040_350]
  @payload_codes [:bad_path, :bad_file, :unexpected_shape]

  @spec map(term()) :: map()
  def map(%OpenAPIError{} = error) do
    %{
      "kind" => kind(error),
      "message" => message(error),
      "details" => details(error)
    }
  end

  def map(%{"kind" => _kind} = error), do: error
  def map({:error, reason}), do: map(reason)
  def map(reason), do: unknown(inspect(reason, limit: 5))

  @spec config(String.t(), map()) :: map()
  def config(message, details \\ %{}), do: error("config", message, details)

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: error("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: error("unsupported", message, details)

  @spec ignored(atom() | String.t()) :: map()
  def ignored(reason),
    do: error("ignored", "Feishu event ignored", %{"reason" => to_string(reason)})

  @spec unknown(String.t()) :: map()
  def unknown(message), do: error("unknown", message, %{})

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%OpenAPIError{code: code}), do: code in @reply_target_missing_codes
  def reply_target_missing?(_error), do: false

  defp error(kind, message, details) do
    %{
      "kind" => kind,
      "message" => message,
      "details" => safe_details(details)
    }
  end

  defp kind(%OpenAPIError{code: :transport}), do: "network"
  defp kind(%OpenAPIError{code: :rate_limited}), do: "rate_limit"
  defp kind(%OpenAPIError{http_status: 429}), do: "rate_limit"
  defp kind(%OpenAPIError{http_status: status}) when status in [401, 403], do: "auth"
  defp kind(%OpenAPIError{code: code}) when code in @rate_limit_codes, do: "rate_limit"
  defp kind(%OpenAPIError{code: code}) when code in @auth_codes, do: "auth"
  defp kind(%OpenAPIError{code: code}) when code in @payload_codes, do: "payload"
  defp kind(%OpenAPIError{}), do: "unknown"

  defp message(%OpenAPIError{msg: msg}) when is_binary(msg) and msg != "", do: msg
  defp message(%OpenAPIError{} = error), do: Exception.message(error)

  defp details(%OpenAPIError{} = error) do
    %{}
    |> maybe_put("code", error.code)
    |> maybe_put("http_status", error.http_status)
    |> maybe_put("log_id", error.log_id)
    |> maybe_put("retry_after_ms", retry_after_ms(error))
  end

  defp retry_after_ms(%OpenAPIError{details: %{} = details}) do
    details["retry_after_ms"] || details[:retry_after_ms] || details["retry_after"] ||
      details[:retry_after]
  end

  defp retry_after_ms(%OpenAPIError{}), do: nil

  defp safe_details(details) when is_map(details) do
    details
    |> Map.new(fn {key, value} -> {to_string(key), json_scalar(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_details(_details), do: %{}

  defp json_scalar(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: value

  defp json_scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp json_scalar(nil), do: nil
  defp json_scalar(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
