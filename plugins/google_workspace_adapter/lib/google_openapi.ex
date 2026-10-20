defmodule GoogleOpenAPI do
  import IMTransport.HTTP, only: [decoded_body: 1, put_body: 2, retry_after: 1]

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

  defp rate_limited_error(%Req.Response{status: status, body: body} = response) do
    {:error,
     %Error{
       reason: :rate_limited,
       status: status,
       retry_after: retry_after(response),
       raw: decoded_body(body)
     }}
  end

  defp error_reason(%{"error" => %{"errors" => [%{"reason" => reason} | _rest]}})
       when is_binary(reason),
       do: reason

  defp error_reason(%{"error" => %{"status" => status}}) when is_binary(status), do: status
  defp error_reason(%{"error" => error}) when is_binary(error), do: error
  defp error_reason(_body), do: :http_error

  defp maybe_put_req(opts, _key, nil), do: opts
  defp maybe_put_req(opts, key, value), do: Keyword.put(opts, key, value)
end
