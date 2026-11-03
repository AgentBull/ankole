defmodule Ankole.Files.HTTP do
  @moduledoc "Bounded HTTP streams for MCP and file transfers, outside database transactions."
  @json_bytes 5_000_000
  @chunk_bytes 8 * 1024 * 1024
  defmodule Error do
    defexception [:reason, sent?: false]
    def message(error), do: inspect(error.reason)
  end

  def json(method, url, headers, body, opts \\ []) do
    bytes = Torque.encode!(body)

    if byte_size(bytes) > @json_bytes do
      {:error, %{code: :json_too_large, retryable: false}}
    else
      with {:ok, response} <- request(method, url, headers, bytes, opts),
           true <- String.valid?(response.body),
           {:ok, decoded} <- Torque.decode(response.body) do
        {:ok, %{response | body: decoded}}
      else
        false -> {:error, %{code: :invalid_utf8, retryable: false}}
        {:error, _} = error -> error
      end
    end
  end

  def request(method, url, headers, body, opts \\ []) do
    Ankole.Repo.assert_outside_transaction!()
    state = open(method, url, headers, body, opts)

    try do
      limit = Keyword.get(opts, :max_bytes, @json_bytes)
      with {:ok, response} <- collect(state, [], 0, limit), do: decode_body(response, limit)
    after
      Mint.HTTP.close(state.conn)
    end
  rescue
    error in Error -> failure(error, opts)
  end

  def stream(method, url, headers, body, opts \\ []) do
    Stream.resource(
      fn -> open(method, url, headers, body, opts) end,
      fn state ->
        {data, state} = receive_data(state)

        if state.status && state.status >= 400,
          do: raise(Error, reason: {:http_status, state.status}, sent?: true)

        if state.done and data == [], do: {:halt, state}, else: {data, state}
      end,
      fn state -> Mint.HTTP.close(state.conn) end
    )
  end

  def upload(actor, file_ref, method, url, headers, opts \\ []) do
    with {:ok, page, path} <- Ankole.Pod.Files.parse_path(file_ref),
         {:ok, file} <- Ankole.Pod.Files.resolve_read(actor, page, path),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      body =
        Stream.unfold(0, fn
          offset when offset >= file.size ->
            nil

          offset ->
            case Ankole.Files.read_object_range(object, offset, @chunk_bytes) do
              {:ok, bytes} when byte_size(bytes) > 0 -> {bytes, offset + byte_size(bytes)}
              {:error, reason} -> raise Error, reason: reason
            end
        end)

      request(method, url, [{"content-length", to_string(file.size)} | headers], body, opts)
    end
  end

  def download(actor, url, headers, destination, opts \\ []) do
    body = stream("GET", url, headers, nil, opts)

    Ankole.Pod.Files.upload(
      actor,
      destination.page_id,
      destination.role,
      Map.get(destination, :base_object_id),
      destination.name,
      body,
      Map.get(destination, :content_type),
      actor.turn_authority
    )
  rescue
    error in Error -> failure(error, Keyword.put(opts, :idempotent, true))
  end

  defp open(method, url, headers, body, opts) do
    Ankole.Repo.assert_outside_transaction!()
    uri = URI.parse(url)

    scheme =
      case uri do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :https
        %URI{scheme: "http", host: host} when is_binary(host) and host != "" -> :http
        _ -> raise Error, reason: :invalid_url
      end

    timeout = Keyword.get(opts, :timeout, 60_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    case Mint.HTTP.connect(scheme, uri.host, uri.port,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} ->
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        try do
          {conn, ref} = send_request(conn, method, path, headers, body)
          %{conn: conn, ref: ref, status: nil, headers: [], done: false, deadline: deadline}
        rescue
          error ->
            Mint.HTTP.close(conn)
            reraise(error, __STACKTRACE__)
        end

      {:error, reason} ->
        raise Error, reason: reason
    end
  end

  defp send_request(conn, method, path, headers, body) do
    streaming? = not is_binary(body) and not is_nil(body)

    case Mint.HTTP.request(conn, method, path, headers, if(streaming?, do: :stream, else: body)) do
      {:ok, conn, ref} ->
        conn = if streaming?, do: Enum.reduce(body, conn, &send_chunk(&2, ref, &1)), else: conn
        conn = if streaming?, do: send_chunk(conn, ref, :eof), else: conn
        {conn, ref}

      {:error, _conn, reason} ->
        raise Error, reason: reason, sent?: true
    end
  rescue
    error in Error -> reraise %{error | sent?: true}, __STACKTRACE__
  end

  defp send_chunk(conn, ref, bytes) do
    case Mint.HTTP.stream_request_body(conn, ref, bytes) do
      {:ok, conn} -> conn
      {:error, _conn, reason} -> raise Error, reason: reason, sent?: true
    end
  end

  defp receive_data(%{done: true} = state), do: {[], state}

  defp receive_data(state) do
    timeout = max(0, state.deadline - System.monotonic_time(:millisecond))

    case Mint.HTTP.recv(state.conn, 0, timeout) do
      {:ok, conn, responses} ->
        Enum.reduce(responses, {[], %{state | conn: conn}}, fn
          {:status, _, status}, {data, s} -> {data, %{s | status: status}}
          {:headers, _, headers}, {data, s} -> {data, %{s | headers: s.headers ++ headers}}
          {:data, _, bytes}, {data, s} -> {[bytes | data], s}
          {:done, _}, {data, s} -> {data, %{s | done: true}}
        end)
        |> then(fn {data, state} -> {Enum.reverse(data), state} end)

      {:error, _conn, reason, _responses} ->
        raise Error, reason: reason, sent?: true
    end
  end

  defp collect(state, parts, size, limit) do
    {data, state} = receive_data(state)
    size = size + IO.iodata_length(data)
    if size > limit, do: raise(Error, reason: :json_too_large, sent?: true)
    parts = [parts, data]

    if state.done,
      do:
        {:ok, %{status: state.status, headers: state.headers, body: IO.iodata_to_binary(parts)}},
      else: collect(state, parts, size, limit)
  end

  defp failure(error, opts) do
    unknown? = error.sent? and not Keyword.get(opts, :idempotent, false)

    {:error,
     %{
       code: if(unknown?, do: "upstream_outcome_unknown", else: "http_request_failed"),
       reason: inspect(error.reason),
       retryable: not unknown? and error.reason != :invalid_url,
       request_sent: error.sent?
     }}
  end

  defp decode_body(response, limit) do
    case List.keyfind(response.headers, "content-encoding", 0) do
      {_, encoding} when encoding in ["gzip", "deflate"] ->
        z = :zlib.open()

        try do
          :ok = :zlib.inflateInit(z, if(encoding == "gzip", do: 31, else: 15))
          body = inflate(z, response.body, [], 0, limit)
          :ok = :zlib.inflateEnd(z)

          headers =
            Enum.reject(response.headers, fn {key, _} ->
              key in ["content-encoding", "content-length"]
            end)

          {:ok, %{response | body: body, headers: headers}}
        rescue
          _ in ErlangError ->
            reraise Error.exception(reason: :invalid_compressed_response, sent?: true),
                    __STACKTRACE__
        after
          :zlib.close(z)
        end

      _ ->
        {:ok, response}
    end
  end

  defp inflate(z, data, parts, size, limit) do
    {status, output} = :zlib.safeInflate(z, data)
    size = size + IO.iodata_length(output)
    if size > limit, do: raise(Error, reason: :json_too_large, sent?: true)
    parts = [parts, output]

    case status do
      :continue -> inflate(z, [], parts, size, limit)
      :finished -> IO.iodata_to_binary(parts)
    end
  end
end
