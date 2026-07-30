defmodule WeComOpenAPI do
  @moduledoc """
  Thin WeCom corp REST client used by Ankole's WeCom adapter.

  All corp server APIs live on `https://qyapi.weixin.qq.com`: the access token
  rides in the `access_token` query parameter and failure is HTTP 200 + non-zero
  `errcode`, normalized into `WeComOpenAPI.Error`.

  ## Tokens

  `:token` selects the credential: `:corp` (default) resolves the cached access
  token for the client's `{corp_id, secret}` pair through
  `WeComOpenAPI.TokenManager`; `nil` sends no token (the `gettoken` fetch
  itself). WeCom may invalidate a token before its nominal expiry, so a
  `:auth`-class failure invalidates the cache and retries once with a fresh
  token before surfacing the error.

  The bot WebSocket channel does not go through this module; see
  `WeComOpenAPI.Bot.Client`.
  """

  alias WeComOpenAPI.{Corp.Client, Error, TokenManager}

  @type token_opt :: :corp | nil

  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, path, opts \\ []), do: request(client, :get, path, opts)

  @spec post(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(%Client{} = client, path, opts \\ []), do: request(client, :post, path, opts)

  @doc """
  Perform a request. `opts`:

    * `:body` — map serialized as JSON.
    * `:query` — keyword list or map of query params.
    * `:token` — `:corp` (default) or `nil`.
  """
  @spec request(Client.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(%Client{} = client, method, path, opts \\ []) do
    token_opt = Keyword.get(opts, :token, :corp)

    case do_request(client, method, path, opts, token_opt) do
      {:error, %Error{reason: :auth}} when token_opt == :corp ->
        TokenManager.invalidate(client)
        do_request(client, method, path, opts, token_opt)

      other ->
        other
    end
  end

  @doc """
  Download raw bytes from an absolute URL (e.g. a bot media temp link).
  Returns the body and any filename parsed from `content-disposition`.
  """
  @spec download(String.t(), keyword()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(url, req_options \\ []) when is_binary(url) do
    req_opts =
      [method: :get, url: url, decode_body: false, redirect: true]
      |> Keyword.merge(req_options)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) ->
        {:ok, %{body: body, filename: filename_from_headers(headers)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: :unexpected_shape, http_status: status, raw: decoded(body)}}

      {:error, reason} ->
        {:error, Error.transport(reason)}
    end
  end

  defp do_request(%Client{} = client, method, path, opts, token_opt) do
    with {:ok, token} <- resolve_token(client, token_opt) do
      url = build_url(client.base_url, path)
      query = opts |> Keyword.get(:query) |> normalize_query() |> put_token(token)

      req_opts =
        [
          method: method,
          url: url,
          headers: client.headers,
          decode_body: false,
          retry: false
        ]
        |> maybe_put(:params, query)
        |> put_body(opts)
        |> Keyword.merge(client.req_options)
        |> Keyword.merge(Keyword.get(opts, :req_options, []))

      case Req.request(req_opts) do
        {:ok, %Req.Response{} = response} -> decode_response(response)
        {:error, reason} -> {:error, Error.transport(reason)}
      end
    end
  end

  defp build_url(base_url, path) do
    cond do
      String.match?(path, ~r/^https?:\/\//i) -> path
      String.starts_with?(path, "/") -> base_url <> path
      true -> base_url <> "/" <> path
    end
  end

  defp resolve_token(_client, nil), do: {:ok, nil}
  defp resolve_token(%Client{} = client, :corp), do: TokenManager.get_corp_token(client)

  defp put_token(query, nil), do: query

  defp put_token(query, token) when is_binary(token) do
    (query || []) |> to_query_list() |> Keyword.put(:access_token, token)
  end

  defp decode_response(%Req.Response{status: 200} = response) do
    case decoded(response.body) do
      %{"errcode" => 0} = body -> {:ok, body}
      %{"errcode" => _code} = body -> {:error, Error.from_body(body, 200)}
      body when is_map(body) -> {:ok, body}
      body -> {:error, %Error{reason: :unexpected_shape, http_status: 200, raw: body}}
    end
  end

  defp decode_response(%Req.Response{status: status} = response) do
    {:error, %Error{reason: :unexpected_shape, http_status: status, raw: decoded(response.body)}}
  end

  defp decoded(body) when is_map(body), do: body
  defp decoded(""), do: %{}
  defp decoded(nil), do: %{}

  defp decoded(body) when is_binary(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decoded(body), do: body

  defp put_body(req_opts, opts) do
    case Keyword.fetch(opts, :body) do
      {:ok, body} ->
        req_opts
        |> Keyword.put(:body, Torque.encode!(body))
        |> Keyword.update!(:headers, &(&1 ++ [{"content-type", "application/json"}]))

      :error ->
        req_opts
    end
  end

  defp normalize_query(nil), do: nil
  defp normalize_query(query) when is_map(query), do: Enum.to_list(query)
  defp normalize_query(query) when is_list(query), do: query

  defp to_query_list(query) when is_list(query), do: query
  defp to_query_list(query) when is_map(query), do: Enum.to_list(query)

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
