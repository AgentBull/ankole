defmodule DingTalkOpenAPI do
  @moduledoc """
  Thin DingTalk OpenAPI client used by Ankole's DingTalk adapter.

  Routes requests to the correct domain by path, injects the app access token
  where each domain expects it, and normalizes both error dialects into
  `DingTalkOpenAPI.Error`.

  ## Domain routing

  Paths beginning with `topapi/` or `media/` (leading slash optional) hit the old
  domain (`oapi.dingtalk.com`): the token rides in the `access_token` query
  parameter and failure is HTTP 200 + non-zero `errcode`. Everything else hits
  the new domain (`api.dingtalk.com`): the token rides in the
  `x-acs-dingtalk-access-token` header and failure is an HTTP non-2xx status.

  ## Tokens

  `:token` selects the credential: `:app` (default) resolves the cached app
  access token through `DingTalkOpenAPI.TokenManager`; `{:user, token}` uses a
  caller-supplied user access token verbatim (new-domain header only); `nil`
  sends no token (token fetch, OAuth code exchange).
  """

  alias DingTalkOpenAPI.{Client, Error, TokenManager}

  @type token_opt :: :app | {:user, String.t()} | nil

  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, path, opts \\ []), do: request(client, :get, path, opts)

  @spec post(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(%Client{} = client, path, opts \\ []), do: request(client, :post, path, opts)

  @spec put(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def put(%Client{} = client, path, opts \\ []), do: request(client, :put, path, opts)

  @spec delete(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete(%Client{} = client, path, opts \\ []), do: request(client, :delete, path, opts)

  @doc """
  Perform a request. `opts`:

    * `:body` — map serialized as JSON.
    * `:form_multipart` — multipart body (media upload); mutually exclusive with
      `:body`.
    * `:query` — keyword list or map of query params.
    * `:token` — `:app` (default), `{:user, token}`, or `nil`.
  """
  @spec request(Client.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(%Client{} = client, method, path, opts \\ []) do
    domain = domain_for(path)

    with {:ok, token} <- resolve_token(client, Keyword.get(opts, :token, :app)) do
      url = build_url(Client.base_url(client, domain), path)
      query = normalize_query(Keyword.get(opts, :query)) |> put_old_domain_token(domain, token)
      headers = new_domain_headers(domain, token) ++ client.headers

      req_opts =
        [method: method, url: url, headers: headers, decode_body: false, retry: false]
        |> maybe_put(:params, query)
        |> put_body(opts)
        |> Keyword.merge(client.req_options)
        |> Keyword.merge(Keyword.get(opts, :req_options, []))

      case Req.request(req_opts) do
        {:ok, %Req.Response{} = response} -> decode_response(domain, response)
        {:error, reason} -> {:error, Error.transport(reason)}
      end
    end
  end

  @doc """
  Download raw bytes from an absolute URL (e.g. a media temp download link).
  Returns the body and any filename parsed from `content-disposition`.
  """
  @spec download(Client.t(), String.t(), keyword()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(%Client{} = client, url, opts \\ []) when is_binary(url) do
    req_opts =
      [method: :get, url: url, decode_body: false, redirect: true]
      |> Keyword.merge(client.req_options)
      |> Keyword.merge(opts)

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

  # --- domain / url --------------------------------------------------------

  defp domain_for(path) do
    trimmed = String.trim_leading(path, "/")

    if String.starts_with?(trimmed, "topapi/") or String.starts_with?(trimmed, "media/") do
      :old
    else
      :new
    end
  end

  defp build_url(base_url, path) do
    cond do
      String.match?(path, ~r/^https?:\/\//i) -> path
      String.starts_with?(path, "/") -> base_url <> path
      true -> base_url <> "/" <> path
    end
  end

  # --- token ---------------------------------------------------------------

  defp resolve_token(_client, nil), do: {:ok, nil}
  defp resolve_token(_client, {:user, token}) when is_binary(token), do: {:ok, token}
  defp resolve_token(%Client{} = client, :app), do: TokenManager.get_app_token(client)

  defp new_domain_headers(:new, token) when is_binary(token),
    do: [{"x-acs-dingtalk-access-token", token}]

  defp new_domain_headers(_domain, _token), do: []

  defp put_old_domain_token(query, :old, token) when is_binary(token) do
    (query || []) |> to_query_list() |> Keyword.put(:access_token, token)
  end

  defp put_old_domain_token(query, _domain, _token), do: query

  # --- response decode -----------------------------------------------------

  defp decode_response(:new, %Req.Response{status: 429} = response) do
    {:error,
     %Error{
       reason: :rate_limited,
       http_status: 429,
       retry_after: retry_after(response.headers),
       raw: decoded(response.body)
     }}
  end

  defp decode_response(:new, %Req.Response{status: status} = response)
       when status in 200..299 do
    {:ok, decoded_map(response.body)}
  end

  defp decode_response(:new, %Req.Response{status: status} = response) do
    case decoded(response.body) do
      body when is_map(body) ->
        {:error, Error.from_new_domain(body, status, retry_after(response.headers))}

      body ->
        {:error, %Error{reason: :unexpected_shape, http_status: status, raw: body}}
    end
  end

  defp decode_response(:old, %Req.Response{status: 200} = response) do
    case decoded(response.body) do
      %{"errcode" => 0} = body -> {:ok, body}
      %{"errcode" => _code} = body -> {:error, Error.from_old_domain(body, 200)}
      body when is_map(body) -> {:ok, body}
      body -> {:error, %Error{reason: :unexpected_shape, http_status: 200, raw: body}}
    end
  end

  defp decode_response(:old, %Req.Response{status: status} = response) do
    {:error, %Error{reason: :unexpected_shape, http_status: status, raw: decoded(response.body)}}
  end

  defp decoded_map(body) do
    case decoded(body) do
      map when is_map(map) -> map
      _other -> %{}
    end
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

  # --- request body / headers ---------------------------------------------

  defp put_body(req_opts, opts) do
    cond do
      Keyword.has_key?(opts, :form_multipart) ->
        Keyword.put(req_opts, :form_multipart, Keyword.fetch!(opts, :form_multipart))

      Keyword.has_key?(opts, :body) ->
        req_opts
        |> Keyword.put(:body, Torque.encode!(Keyword.fetch!(opts, :body)))
        |> Keyword.update!(:headers, &(&1 ++ [{"content-type", "application/json"}]))

      true ->
        req_opts
    end
  end

  defp normalize_query(nil), do: nil
  defp normalize_query(query) when is_map(query), do: Enum.to_list(query)
  defp normalize_query(query) when is_list(query), do: query

  defp to_query_list(query) when is_list(query), do: query
  defp to_query_list(query) when is_map(query), do: Enum.to_list(query)

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
