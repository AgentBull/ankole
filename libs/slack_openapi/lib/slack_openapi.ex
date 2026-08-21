defmodule SlackOpenAPI do
  @moduledoc "Thin Slack Web API client used by Ankole's Slack adapter."

  alias SlackOpenAPI.{Client, Error}

  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, method, opts \\ []) do
    request(client, :get, method, opts)
  end

  @spec post(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(%Client{} = client, method, opts \\ []) do
    request(client, :post, method, opts)
  end

  @spec download(Client.t(), String.t(), keyword()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(%Client{} = client, url, opts \\ []) when is_binary(url) do
    headers = bearer_headers(Client.bot_token(client))

    req_opts =
      [method: :get, url: url, headers: headers, redirect: true, decode_body: false]
      |> Keyword.merge(client.req_options)
      |> Keyword.merge(opts)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) ->
        {:ok, %{body: body, filename: filename_from_headers(headers)}}

      {:ok, %Req.Response{} = response} ->
        {:error, response_error(response)}

      {:error, reason} ->
        {:error, %Error{reason: :transport, raw: reason}}
    end
  end

  @spec upload_external(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def upload_external(%Client{} = client, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content = IO.iodata_to_binary(Keyword.fetch!(opts, :content))

    with {:ok, %{"upload_url" => upload_url, "file_id" => file_id}} <-
           get(client, "files.getUploadURLExternal",
             query: [filename: filename, length: byte_size(content)]
           ),
         {:ok, _response} <- upload_bytes(upload_url, content, client.req_options),
         body <-
           %{"files" => [%{"id" => file_id, "title" => filename}]}
           |> put_present("channel_id", Keyword.get(opts, :channel_id))
           |> put_present("thread_ts", Keyword.get(opts, :thread_ts))
           |> put_present("initial_comment", Keyword.get(opts, :initial_comment)),
         {:ok, result} <- post(client, "files.completeUploadExternal", body: body) do
      {:ok, result}
    end
  end

  defp request(client, http_method, method, opts) do
    token = Keyword.get(opts, :token, :bot)
    url = build_url(client.base_url, method)

    req_opts =
      [
        method: http_method,
        url: url,
        headers: bearer_headers(resolve_token(client, token)),
        decode_body: false,
        retry: false
      ]
      |> maybe_put_req(:params, Keyword.get(opts, :query))
      |> put_body(opts)
      |> Keyword.merge(client.req_options)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = response} -> decode_response(response)
      {:error, reason} -> {:error, %Error{reason: :transport, raw: reason}}
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

  defp decode_response(%Req.Response{status: status} = response) when status in 200..299 do
    case decoded_body(response.body) do
      %{"ok" => true} = body ->
        {:ok, normalize_success_body(body)}

      %{"ok" => false, "error" => reason} = body ->
        {:error, %Error{reason: reason, status: status, raw: body}}

      body when is_map(body) ->
        {:error, %Error{reason: :unexpected_shape, status: status, raw: body}}

      body ->
        {:error, %Error{reason: :unexpected_shape, status: status, raw: body}}
    end
  end

  defp decode_response(%Req.Response{} = response), do: {:error, response_error(response)}

  defp response_error(%Req.Response{status: status, body: body}) do
    decoded = decoded_body(body)
    reason = if is_map(decoded), do: Map.get(decoded, "error", :http_error), else: :http_error
    %Error{reason: reason, status: status, raw: decoded}
  end

  defp decoded_body(body) when is_map(body), do: body

  defp decoded_body(body) when is_binary(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decoded_body(body), do: body

  defp normalize_success_body(%{"ts" => value} = body) when is_integer(value),
    do: Map.put(body, "ts", Integer.to_string(value))

  defp normalize_success_body(%{"ts" => value} = body) when is_float(value),
    do: Map.put(body, "ts", :erlang.float_to_binary(value, [:compact, decimals: 6]))

  defp normalize_success_body(body), do: body

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

  defp resolve_token(_client, nil), do: nil
  defp resolve_token(client, :bot), do: Client.bot_token(client)
  defp resolve_token(client, :app), do: Client.app_token(client)
  defp resolve_token(_client, {:bearer, token}) when is_binary(token), do: token

  defp bearer_headers(nil), do: []
  defp bearer_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp build_url(base_url, method) do
    if String.match?(method, ~r/^https?:\/\//i),
      do: method,
      else: base_url <> "/" <> String.trim_leading(method, "/")
  end

  defp upload_bytes(url, content, req_options) do
    request_opts =
      [
        url: url,
        method: :post,
        body: content,
        headers: [{"content-type", "application/octet-stream"}],
        decode_body: false,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{} = response} -> {:error, response_error(response)}
      {:error, reason} -> {:error, %Error{reason: :transport, raw: reason}}
    end
  end

  defp retry_after(headers) do
    headers
    |> header_value("retry-after")
    |> case do
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

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_req(opts, _key, nil), do: opts
  defp maybe_put_req(opts, key, value), do: Keyword.put(opts, key, value)
end
