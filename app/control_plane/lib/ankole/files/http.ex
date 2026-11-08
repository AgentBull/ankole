defmodule Ankole.Files.HTTP do
  @moduledoc """
  Bounded HTTP streams for MCP and file transfers, outside database transactions.

  A caller adds TLS client options, such as a custom CA or
  `verify: :verify_none`, to an `https` connection through `:transport_opts`.
  """
  @json_bytes 5_000_000
  @chunk_bytes 8 * 1024 * 1024
  @error_body_bytes 64 * 1024
  defmodule Error do
    # For a streamed error status, `body` holds the first 64 KiB of the response,
    # so the caller can report the server's own message.
    defexception [:reason, :body, sent?: false]
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
    opts = with_deadline(opts)
    state = open(method, url, headers, body, opts)

    result =
      try do
        limit = Keyword.get(opts, :max_bytes, @json_bytes)
        with {:ok, response} <- collect(state, [], 0, limit), do: decode_body(response, limit)
      after
        Mint.HTTP.close(state.conn)
      end

    case result do
      {:ok, %{status: status, headers: response_headers}}
      when status in [301, 302, 303, 307, 308] and method in ["GET", "HEAD"] ->
        {next_url, next_headers, next_opts} = redirect(url, headers, response_headers, opts)
        request(method, next_url, next_headers, body, next_opts)

      result ->
        result
    end
  rescue
    error in Error -> failure(error, opts)
  end

  def stream(method, url, headers, body, opts \\ []) do
    Stream.resource(
      fn -> open_stream(method, url, headers, body, opts) end,
      fn
        {state, [_ | _] = buffered} ->
          {buffered, {state, []}}

        {state, []} ->
          {data, state} = receive_data(state)

          if state.status && state.status >= 400,
            do: raise(Error, reason: {:http_status, state.status}, sent?: true)

          if state.done and data == [], do: {:halt, {state, []}}, else: {data, {state, []}}
      end,
      fn {state, _} -> Mint.HTTP.close(state.conn) end
    )
  end

  defp open_stream(method, url, headers, body, opts) do
    opts = with_deadline(opts)
    state = open(method, url, headers, body, opts)

    {data, state} =
      try do
        stream_head(state, [])
      rescue
        error ->
          Mint.HTTP.close(state.conn)
          reraise(error, __STACKTRACE__)
      end

    cond do
      state.status in [301, 302, 303, 307, 308] and method == "GET" ->
        Mint.HTTP.close(state.conn)
        {next_url, next_headers, next_opts} = redirect(url, headers, state.headers, opts)
        open_stream(method, next_url, next_headers, body, next_opts)

      state.status >= 400 ->
        body =
          try do
            error_body(state, data)
          rescue
            _ in Error -> nil
          after
            Mint.HTTP.close(state.conn)
          end

        raise Error, reason: {:http_status, state.status}, sent?: true, body: body

      true ->
        {state, data}
    end
  end

  defp error_body(state, parts) do
    size = IO.iodata_length(parts)

    if state.done or size >= @error_body_bytes do
      parts |> IO.iodata_to_binary() |> binary_part(0, min(size, @error_body_bytes))
    else
      {data, state} = receive_data(state)
      error_body(state, [parts, data])
    end
  end

  defp stream_head(%{status: nil} = state, parts) do
    {data, state} = receive_data(state)
    stream_head(state, parts ++ data)
  end

  defp stream_head(state, parts), do: {parts, state}

  defp with_deadline(opts) do
    Keyword.put_new_lazy(opts, :deadline, fn ->
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 60_000)
    end)
  end

  defp redirect(url, headers, response_headers, opts) do
    count = Keyword.get(opts, :redirects, 0)
    location = List.keyfind(response_headers, "location", 0)
    if count >= 5 or is_nil(location), do: raise(Error, reason: :invalid_redirect, sent?: true)
    next = URI.merge(url, elem(location, 1))
    previous = URI.parse(url)

    headers =
      if {previous.scheme, previous.host, previous.port} == {next.scheme, next.host, next.port},
        do: headers,
        else:
          Enum.reject(headers, fn {key, _} ->
            String.downcase(key) in ["authorization", "cookie"]
          end)

    {URI.to_string(next), headers, Keyword.put(opts, :redirects, count + 1)}
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

    deadline = Keyword.fetch!(opts, :deadline)
    remaining!(deadline)

    {:ok, ssrf_filter} = Ankole.Security.SSRFFilter.enabled?()

    with :ok <- Ankole.Kernel.validate_web_url(url, ["http", "https"], ssrf_filter),
         addresses =
           Enum.flat_map([:inet, :inet6], fn family ->
             case :inet.getaddrs(String.to_charlist(uri.host), family) do
               {:ok, addresses} -> addresses
               _ -> []
             end
           end),
         true <- addresses != [],
         :ok <-
           Ankole.Kernel.validate_ip_addresses(
             Enum.map(addresses, &to_string(:inet.ntoa(&1))),
             ssrf_filter
           ) do
      proxy = Keyword.get(Ankole.EgressProxy.req_options(url), :connect_options, [])
      target = if proxy == [], do: hd(addresses), else: uri.host

      connect_options =
        Keyword.merge(
          [
            mode: :passive,
            protocols: [:http1],
            hostname: uri.host,
            transport_opts:
              [timeout: remaining!(deadline)] ++ Keyword.get(opts, :transport_opts, [])
          ],
          proxy
        )

      connect(scheme, target, uri, method, headers, body, deadline, connect_options)
    else
      false -> raise Error, reason: :nxdomain
      {:error, reason} -> raise Error, reason: reason
    end
  end

  defp connect(scheme, target, uri, method, headers, body, deadline, options) do
    case Mint.HTTP.connect(scheme, target, uri.port, options) do
      {:ok, conn} ->
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        try do
          remaining!(deadline)
          {conn, ref} = send_request(conn, method, path, headers, body, deadline)
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

  defp send_request(conn, method, path, headers, body, deadline) do
    streaming? = not is_binary(body) and not is_nil(body)

    case Mint.HTTP.request(conn, method, path, headers, if(streaming?, do: :stream, else: body)) do
      {:ok, conn, ref} ->
        conn =
          if streaming?,
            do: Enum.reduce(body, conn, &send_chunk(&2, ref, &1, deadline)),
            else: conn

        conn = if streaming?, do: send_chunk(conn, ref, :eof, deadline), else: conn
        {conn, ref}

      {:error, _conn, reason} ->
        raise Error, reason: reason, sent?: true
    end
  rescue
    error in Error -> reraise %{error | sent?: true}, __STACKTRACE__
  end

  defp send_chunk(conn, ref, bytes, deadline) do
    remaining!(deadline)

    case Mint.HTTP.stream_request_body(conn, ref, bytes) do
      {:ok, conn} -> conn
      {:error, _conn, reason} -> raise Error, reason: reason, sent?: true
    end
  end

  defp remaining!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise(Error, reason: :timeout)
    remaining
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

    status =
      case error.reason do
        {:http_status, status} -> %{status: status}
        _ -> %{}
      end

    {:error,
     Map.merge(status, %{
       code: if(unknown?, do: "upstream_outcome_unknown", else: "http_request_failed"),
       reason: inspect(error.reason),
       retryable: not unknown? and error.reason != :invalid_url,
       request_sent: error.sent?
     })}
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
