defmodule MicrosoftOpenAPI do
  @moduledoc """
  Thin Microsoft HTTP client used by Ankole's Microsoft 365 adapter.

  This module owns the shared request/decode/error mechanics. Domain modules
  (`EntraAuth`, `Graph`, `BotConnector`, `BotOpenID`) build URLs and auth on
  top of it. Unlike Slack's `"ok"` envelope, Microsoft endpoints use plain
  HTTP semantics: 2xx JSON is success, error bodies carry `error.code`
  (Graph/Bot Connector) or `error` (OAuth), and 429 carries `Retry-After`.
  """

  alias MicrosoftOpenAPI.Error

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

  @doc """
  Downloads a binary resource, following redirects.

  Teams file-consent attachments serve pre-authorized download URLs that need
  no auth header; connector-hosted attachment URLs need a Bot Framework bearer
  passed through `:headers`.
  """
  @spec download(String.t(), keyword()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(url, opts \\ []) when is_binary(url) do
    req_opts =
      [
        method: :get,
        url: url,
        headers: Keyword.get(opts, :headers, []),
        redirect: true,
        decode_body: false,
        retry: false
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) ->
        {:ok, %{body: body, filename: filename_from_headers(headers)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: error_reason(decoded_body(body)), status: status, raw: body}}

      {:error, reason} ->
        {:error, %Error{reason: :transport, raw: reason}}
    end
  end

  defp filename_from_headers(headers) do
    case header_value(headers, "content-disposition") do
      value when is_binary(value) ->
        case Regex.run(~r/filename\*?=(?:UTF-8''|\")?([^\";]+)/i, value, capture: :all_but_first) do
          [filename] -> URI.decode(filename)
          _no_match -> nil
        end

      _absent ->
        nil
    end
  end

  defp decode_response(%Req.Response{status: 429} = response) do
    {:error,
     %Error{
       reason: :rate_limited,
       status: 429,
       retry_after: retry_after(response.headers),
       raw: decoded_body(response.body)
     }}
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

  defp error_reason(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_reason(%{"error" => code}) when is_binary(code), do: code
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
