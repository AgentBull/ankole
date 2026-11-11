defmodule Ankole.Files.HTTP do
  @moduledoc """
  Bounded HTTP streams for MCP, link previews, media downloads, and file transfers,
  executed outside database transactions.

  Every hop validates its URL and resolved IP addresses against `security.ssrf_filter`
  and `Ankole.EgressProxy`. Cross-origin redirects strip authentication and custom
  request headers so credentials never leave their origin. A caller adds TLS client
  options, such as a custom CA or `verify: :verify_none`, to an `https` connection
  through `:transport_opts`.
  """
  @json_bytes 5_000_000
  @chunk_bytes 8 * 1024 * 1024
  @error_body_bytes 64 * 1024
  @default_max_redirects 5
  @safe_cross_origin_headers ~w(
    accept
    accept-encoding
    accept-language
    cache-control
    pragma
    range
    user-agent
  )

  defmodule Error do
    # For a streamed error status, `body` holds the first 64 KiB of the response,
    # so the caller can report the server's own message.
    defexception [:reason, :body, sent?: false]
    def message(error), do: inspect(error.reason)
  end

  @doc false
  def safe_redirect_headers(previous_url, next_url, headers)
      when is_binary(previous_url) and is_binary(next_url) and is_list(headers) do
    if same_origin?(URI.parse(previous_url), URI.parse(next_url)) do
      headers
    else
      Enum.filter(headers, fn {key, _value} ->
        String.downcase(to_string(key)) in @safe_cross_origin_headers
      end)
    end
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
      fn ->
        {state, data, _final_url} = open_stream(method, url, headers, body, opts)
        {state, data}
      end,
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

  @doc """
  Opens a streamed HTTP/1 response, follows validated `GET`/`HEAD` redirects, and passes
  `%{status: status, headers: headers, url: final_url}` plus a lazy chunk stream to `fun`.

  Both the Mint connection and any zlib decompression handle are closed in an `after`
  block as soon as `fun` finishes or raises, even when `fun` halts enumeration early.
  """
  def with_stream(method, url, headers, body, opts \\ [], fun) when is_function(fun, 2) do
    Ankole.Repo.assert_outside_transaction!()
    stream_opts = opts |> with_deadline() |> Keyword.put(:allow_error_status, true)
    {state, initial_data, final_url} = open_stream(method, url, headers, body, stream_opts)

    zstream =
      if Keyword.get(stream_opts, :decompress, false),
        do: maybe_open_zstream(state.headers),
        else: nil

    try do
      limit = Keyword.get(stream_opts, :max_bytes)

      chunks =
        Stream.resource(
          fn -> {state, initial_data, 0} end,
          fn
            {_current, _buffered, emitted}
            when is_integer(limit) and emitted >= limit ->
              {:halt, :limit_reached}

            :limit_reached ->
              {:halt, :limit_reached}

            {current, [_ | _] = buffered, emitted} ->
              {decoded, next_emitted} = decode_stream_chunks(zstream, buffered, emitted, limit)
              {decoded, {current, [], next_emitted}}

            {%{done: true} = current, [], emitted} ->
              {:halt, {current, [], emitted}}

            {current, [], emitted} ->
              {data, next_state} = receive_data(current)

              if next_state.done and data == [] do
                {:halt, {next_state, [], emitted}}
              else
                {decoded, next_emitted} = decode_stream_chunks(zstream, data, emitted, limit)
                {decoded, {next_state, [], next_emitted}}
              end
          end,
          fn _acc -> :ok end
        )

      fun.(%{status: state.status, headers: state.headers, url: final_url}, chunks)
    after
      close_zstream(zstream)
      Mint.HTTP.close(state.conn)
    end
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
      state.status in [301, 302, 303, 307, 308] and method in ["GET", "HEAD"] ->
        Mint.HTTP.close(state.conn)
        {next_url, next_headers, next_opts} = redirect(url, headers, state.headers, opts)
        open_stream(method, next_url, next_headers, body, next_opts)

      state.status >= 400 and not Keyword.get(opts, :allow_error_status, false) ->
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
        {state, data, url}
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
    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)

    if count >= max_redirects,
      do: raise(Error, reason: :too_many_redirects, sent?: true)

    location =
      Enum.find_value(response_headers, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          if String.downcase(key) == "location", do: value

        _ ->
          nil
      end)

    if is_nil(location) or String.trim(location) == "",
      do: raise(Error, reason: :invalid_redirect, sent?: true)

    next_url = resolve_redirect_target(url, location, Keyword.get(opts, :resolve_redirect))
    next_headers = safe_redirect_headers(url, next_url, headers)

    {next_url, next_headers, Keyword.put(opts, :redirects, count + 1)}
  end

  defp resolve_redirect_target(url, location, resolver) when is_function(resolver, 2) do
    case resolver.(url, location) do
      {:ok, next_url} when is_binary(next_url) -> next_url
      _ -> raise Error, reason: :invalid_redirect, sent?: true
    end
  end

  defp resolve_redirect_target(url, location, nil) do
    next = URI.merge(url, String.trim(location))

    if next.scheme in ["http", "https"] and is_binary(next.host) and next.host != "" and
         is_nil(next.userinfo) do
      URI.to_string(next)
    else
      raise Error, reason: :invalid_redirect, sent?: true
    end
  rescue
    ArgumentError ->
      reraise Error.exception(reason: :invalid_redirect, sent?: true), __STACKTRACE__
  end

  defp same_origin?(%URI{} = a, %URI{} = b) do
    a.scheme in ["http", "https"] and
      a.scheme == b.scheme and
      is_binary(a.host) and a.host != "" and
      is_binary(b.host) and b.host != "" and
      String.downcase(a.host) == String.downcase(b.host) and
      (a.port || URI.default_port(a.scheme)) == (b.port || URI.default_port(b.scheme))
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
        %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
          :https

        %URI{scheme: "http", host: host, userinfo: nil} when is_binary(host) and host != "" ->
          :http

        _ ->
          raise Error, reason: :invalid_url
      end

    deadline = Keyword.fetch!(opts, :deadline)
    remaining = remaining!(deadline)

    connect_timeout =
      case Keyword.get(opts, :connect_timeout) do
        ms when is_integer(ms) and ms > 0 -> min(ms, remaining)
        _ -> remaining
      end

    ssrf_filter =
      case Keyword.fetch(opts, :ssrf_filter) do
        {:ok, explicit} ->
          explicit == true

        :error ->
          {:ok, enabled?} = Ankole.Security.SSRFFilter.enabled?()
          enabled?
      end

    with :ok <- Ankole.Kernel.validate_web_url(url, ["http", "https"], ssrf_filter),
         {:ok, req_proxy_opts} <-
           Ankole.EgressProxy.resolve_req_options(
             url,
             Keyword.take(opts, [:proxy_url, :require_proxy])
           ),
         {:ok, addresses} <- resolve_addresses(uri.host),
         :ok <-
           Ankole.Kernel.validate_ip_addresses(
             Enum.map(addresses, &to_string(:inet.ntoa(&1))),
             ssrf_filter
           ) do
      proxy = Keyword.get(req_proxy_opts, :connect_options, [])
      target = if proxy == [], do: hd(addresses), else: uri.host

      inet6_opts =
        if proxy == [] and is_tuple(target) and tuple_size(target) == 8,
          do: [inet6: true],
          else: []

      connect_options =
        Keyword.merge(
          [
            mode: :passive,
            protocols: [:http1],
            hostname: strip_ipv6_brackets(uri.host),
            transport_opts:
              [timeout: connect_timeout] ++ inet6_opts ++ Keyword.get(opts, :transport_opts, [])
          ],
          proxy
        )

      connect(
        scheme,
        target,
        uri,
        method,
        headers,
        body,
        deadline,
        Keyword.get(opts, :receive_timeout),
        connect_options
      )
    else
      {:error, reason} -> raise Error, reason: reason
    end
  end

  defp resolve_addresses(host) when is_binary(host) do
    trimmed = strip_ipv6_brackets(host)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        addresses =
          Enum.flat_map([:inet, :inet6], fn family ->
            case :inet.getaddrs(String.to_charlist(trimmed), family) do
              {:ok, resolved} -> resolved
              _ -> []
            end
          end)
          |> Enum.uniq()

        if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
    end
  end

  defp strip_ipv6_brackets(host) do
    host |> String.trim_leading("[") |> String.trim_trailing("]")
  end

  defp connect(scheme, target, uri, method, headers, body, deadline, receive_timeout, options) do
    port = uri.port || URI.default_port(uri.scheme)

    case Mint.HTTP.connect(scheme, target, port, options) do
      {:ok, conn} ->
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        try do
          remaining!(deadline)
          {conn, ref} = send_request(conn, method, path, headers, body, deadline)

          %{
            conn: conn,
            ref: ref,
            status: nil,
            headers: [],
            done: false,
            deadline: deadline,
            receive_timeout: receive_timeout
          }
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
    remaining = state.deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise(Error, reason: :timeout, sent?: true)

    timeout =
      case state.receive_timeout do
        ms when is_integer(ms) and ms > 0 -> min(ms, remaining)
        _ -> remaining
      end

    case Mint.HTTP.recv(state.conn, 0, timeout) do
      {:ok, conn, responses} ->
        apply_responses(responses, %{state | conn: conn})

      {:error, conn, :closed, responses} when responses != [] ->
        {data, next_state} = apply_responses(responses, %{state | conn: conn})

        if next_state.status != nil do
          {data, %{next_state | done: true}}
        else
          raise Error, reason: :closed, sent?: true
        end

      {:error, _conn, reason, _responses} ->
        raise Error, reason: reason, sent?: true
    end
  end

  defp apply_responses(responses, state) do
    Enum.reduce(responses, {[], state}, fn
      {:status, _, status}, {data, s} -> {data, %{s | status: status}}
      {:headers, _, headers}, {data, s} -> {data, %{s | headers: s.headers ++ headers}}
      {:data, _, bytes}, {data, s} -> {[bytes | data], s}
      {:done, _}, {data, s} -> {data, %{s | done: true}}
      _other, acc -> acc
    end)
    |> then(fn {data, next_state} -> {Enum.reverse(data), next_state} end)
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

  defp maybe_open_zstream(headers) do
    encoding =
      Enum.find_value(headers, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          if String.downcase(key) == "content-encoding",
            do: value |> String.trim() |> String.downcase()

        _ ->
          nil
      end)

    if encoding in ["gzip", "x-gzip", "deflate"] do
      z = :zlib.open()
      :ok = :zlib.inflateInit(z, 47)
      z
    else
      nil
    end
  end

  defp close_zstream(nil), do: :ok

  defp close_zstream(z) do
    :zlib.close(z)
  rescue
    ArgumentError -> :ok
  end

  defp decode_stream_chunks(nil, chunks, emitted, limit) do
    clamp_chunks(chunks, emitted, limit)
  end

  defp decode_stream_chunks(zstream, chunks, emitted, limit) do
    decoded =
      Enum.map(chunks, fn chunk ->
        remaining = if is_integer(limit), do: max(limit - emitted, 1), else: @chunk_bytes
        inflate_stream_chunk(zstream, chunk, [], 0, remaining)
      end)

    clamp_chunks(decoded, emitted, limit)
  rescue
    _ in ErlangError ->
      reraise Error.exception(reason: :invalid_compressed_response, sent?: true), __STACKTRACE__
  end

  defp inflate_stream_chunk(zstream, data, parts, size, limit) do
    case :zlib.safeInflate(zstream, data) do
      {:continue, output} ->
        next_size = size + IO.iodata_length(output)
        next_parts = [parts, output]

        if next_size >= limit,
          do: IO.iodata_to_binary(next_parts),
          else: inflate_stream_chunk(zstream, [], next_parts, next_size, limit)

      {:finished, output} ->
        IO.iodata_to_binary([parts, output])

      {:need_dictionary, _adler, _output} ->
        raise Error, reason: :invalid_compressed_response, sent?: true
    end
  end

  defp clamp_chunks(chunks, emitted, nil) do
    non_empty = Enum.reject(chunks, &(&1 == ""))
    {non_empty, emitted + IO.iodata_length(non_empty)}
  end

  defp clamp_chunks(chunks, emitted, limit) do
    Enum.flat_map_reduce(chunks, emitted, fn chunk, count ->
      remaining = max(limit - count, 0)

      cond do
        remaining == 0 or chunk == "" ->
          {[], count}

        byte_size(chunk) > remaining ->
          slice = binary_part(chunk, 0, remaining)
          {[slice], count + remaining}

        true ->
          {[chunk], count + byte_size(chunk)}
      end
    end)
  end

  defp decode_body(response, limit) do
    case List.keyfind(response.headers, "content-encoding", 0) do
      {_, encoding} when encoding in ["gzip", "x-gzip", "deflate"] ->
        z = :zlib.open()

        try do
          :ok = :zlib.inflateInit(z, if(encoding in ["gzip", "x-gzip"], do: 31, else: 15))
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
