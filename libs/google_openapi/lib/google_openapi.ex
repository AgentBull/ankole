defmodule GoogleOpenAPI do
  @moduledoc """
  Thin Google HTTP client used by Ankole's Google Workspace adapter.

  This module owns the shared request/decode/error mechanics. Domain modules
  (`Auth`, `Directory`) build URLs and auth on top of it. Google endpoints use
  plain HTTP semantics: 2xx JSON is success, error bodies carry
  `error.errors[].reason`/`error.status` (admin APIs) or `error` (OAuth), and
  rate limiting arrives as 429 with `Retry-After` or as 403 with a rate-limit
  reason.
  """

  alias GoogleOpenAPI.Error

  @rate_limit_reasons ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded"]

  @type response :: {:ok, map()} | {:error, Error.t()}

  @spec request(atom(), String.t(), keyword()) :: response()
  def request(http_method, url, opts \\ []) when is_atom(http_method) and is_binary(url) do
    req_opts =
      [
        method: http_method,
        url: url,
        headers: Keyword.get(opts, :headers, []),
        decode_body: false,
        retry: false
      ]
      |> maybe_put_req(:params, Keyword.get(opts, :query))
      |> put_body(opts)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = response} -> decode_response(response)
      {:error, reason} -> {:error, %Error{reason: :transport, raw: reason}}
    end
  end

  @spec bearer_headers(String.t() | nil) :: [{String.t(), String.t()}]
  def bearer_headers(nil), do: []
  def bearer_headers(token) when is_binary(token), do: [{"authorization", "Bearer " <> token}]

  defp decode_response(%Req.Response{status: 429} = response) do
    rate_limited_error(response)
  end

  defp decode_response(%Req.Response{status: 403, body: body} = response) do
    decoded = decoded_body(body)

    if error_reason(decoded) in @rate_limit_reasons do
      rate_limited_error(response)
    else
      {:error, %Error{reason: error_reason(decoded), status: 403, raw: decoded}}
    end
  end

  defp decode_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case decoded_body(body) do
      decoded when is_map(decoded) -> {:ok, decoded}
      "" -> {:ok, %{}}
      nil -> {:ok, %{}}
      decoded -> {:error, %Error{reason: :unexpected_shape, status: status, raw: decoded}}
    end
  end

  defp decode_response(%Req.Response{status: status, body: body}) do
    decoded = decoded_body(body)
    %Error{reason: error_reason(decoded), status: status, raw: decoded} |> then(&{:error, &1})
  end

  defp rate_limited_error(%Req.Response{status: status, body: body, headers: headers}) do
    {:error,
     %Error{
       reason: :rate_limited,
       status: status,
       retry_after: retry_after(headers),
       raw: decoded_body(body)
     }}
  end

  defp error_reason(%{"error" => %{"errors" => [%{"reason" => reason} | _rest]}})
       when is_binary(reason),
       do: reason

  defp error_reason(%{"error" => %{"status" => status}}) when is_binary(status), do: status
  defp error_reason(%{"error" => error}) when is_binary(error), do: error
  defp error_reason(_body), do: :http_error

  defp decoded_body(body) when is_map(body), do: body

  defp decoded_body(body) when is_binary(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decoded_body(body), do: body

  defp put_body(req_opts, opts) do
    cond do
      Keyword.has_key?(opts, :body) ->
        req_opts
        |> Keyword.put(:body, Torque.encode!(Keyword.fetch!(opts, :body)))
        |> Keyword.update!(:headers, &(&1 ++ [{"content-type", "application/json"}]))

      Keyword.has_key?(opts, :form) ->
        Keyword.put(req_opts, :form, Keyword.fetch!(opts, :form))

      true ->
        req_opts
    end
  end

  defp retry_after(headers) do
    case header_value(headers, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _rest} -> seconds
          :error -> nil
        end

      _value ->
        nil
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _other -> nil
    end)
  end

  defp maybe_put_req(opts, _key, nil), do: opts
  defp maybe_put_req(opts, key, value), do: Keyword.put(opts, key, value)
end
