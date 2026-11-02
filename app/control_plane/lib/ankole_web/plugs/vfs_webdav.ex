defmodule AnkoleWeb.Plugs.VfsWebdav do
  @moduledoc "Streaming WebDAV entry before the JSON body parser."
  import Plug.Conn
  alias Ankole.{Files, Kernel, Repo}
  alias Ankole.Files.Vfs.{Auth, Content, Namespace, Operations}
  @prefix "/api/v1/vfs/dav"
  @methods "OPTIONS, PROPFIND, HEAD, GET, PUT, MKCOL, MOVE, COPY, DELETE"
  def init(opts), do: opts

  def call(%{method: "POST", path_info: ["api", "v1", "vfs", "refresh"]} = conn, _) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, payload} <- Auth.decode(token, refresh: true),
         {:ok, token} <- Repo.with_tenant(payload["tenant_id"], fn -> Auth.refresh(payload) end),
         do:
           conn
           |> upload_limit_header()
           |> put_resp_content_type("application/json")
           |> send_resp(200, Torque.encode!(%{token: token}))
           |> halt(),
         else: (_ -> failure(conn, :unauthorized) |> halt())
  end

  def call(%{path_info: ["api", "v1", "vfs", "dav" | path]} = conn, _) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, payload} <- Auth.decode(token),
         {:ok, path} <- segments(path) do
      Repo.with_tenant(payload["tenant_id"], fn ->
        case Auth.context(payload) do
          {:ok, scope} ->
            scope =
              if header(conn, "x-ankole-shared-scope") == "1",
                do: %{scope | conversation_id: nil},
                else: scope

            dispatch(conn, scope, path)

          {:error, reason} ->
            failure(conn, reason)
        end
      end)
    else
      {:error, reason} -> failure(conn, reason)
      _ -> failure(conn, :unauthorized)
    end
    |> halt()
  end

  def call(conn, _), do: conn

  defp dispatch(%{method: "OPTIONS"} = conn, _, _),
    do:
      conn
      |> put_resp_header("dav", "1")
      |> put_resp_header("allow", @methods)
      |> upload_limit_header()
      |> send_resp(200, "")

  defp dispatch(%{method: "PROPFIND"} = conn, scope, path) do
    xml_body(conn, fn conn, body -> propfind_response(conn, scope, path, body) end)
  end

  defp dispatch(%{method: method} = conn, scope, path) when method in ["GET", "HEAD"] do
    expected = header(conn, "x-ankole-expected-etag")

    with {:ok, {meta, content}} <- Operations.read(scope, path, expected),
         {:ok, {offset, length, partial?}} <- range(conn, meta.size) do
      conn =
        conn
        |> metadata(meta)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", Integer.to_string(length))

      conn =
        if partial?,
          do:
            put_resp_header(
              conn,
              "content-range",
              "bytes #{offset}-#{offset + length - 1}/#{meta.size}"
            ),
          else: conn

      status = if partial?, do: 206, else: 200

      if method == "HEAD",
        do: send_resp(conn, status, ""),
        else: stream(conn, status, content, offset, length)
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp dispatch(%{method: "PUT"} = conn, scope, path) do
    with {:ok, limit} <- Files.Config.vfs_upload_limit() do
      if Operations.upload_kind(scope, path) == :file do
        {result, conn} = receive_object(conn, limit)

        case result do
          {:ok, stored} -> put_response(conn, scope, path, {:stored, stored})
          {:error, reason} -> failure(conn, reason)
        end
      else
        local = Files.temp_path()

        try do
          case receive_file(conn, local, min(limit, 100 * 1024 * 1024)) do
            {:ok, conn} -> put_response(conn, scope, path, local)
            {:error, reason, conn} -> failure(conn, reason)
            {:error, reason} -> failure(conn, reason)
          end
        after
          File.rm(local)
        end
      end
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp dispatch(%{method: "MKCOL"} = conn, scope, path) do
    case Operations.mkdir(scope, path) do
      {:ok, node} -> conn |> put_resp_header("x-ankole-node-id", node.id) |> send_resp(201, "")
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp dispatch(%{method: method} = conn, scope, path) when method in ["MOVE", "COPY"] do
    operation = if method == "COPY", do: &Operations.copy/4, else: &Operations.move/4

    with {:ok, destination} <- destination(conn),
         {:ok, headers} <- write_headers(conn),
         {:ok, node} <- operation.(scope, path, destination, headers),
         {:ok, meta} <- put_metadata(node),
         do: conn |> metadata(meta) |> send_resp(201, ""),
         else: ({:error, reason} -> failure(conn, reason))
  end

  defp dispatch(%{method: "DELETE"} = conn, scope, path) do
    with {:ok, headers} <- write_headers(conn),
         {:ok, _} <- Operations.delete(scope, path, headers),
         do: send_resp(conn, 204, ""),
         else: ({:error, reason} -> failure(conn, reason))
  end

  defp dispatch(conn, _, _),
    do: conn |> put_resp_header("allow", @methods) |> send_resp(405, "unsupported DAV method")

  defp propfind_response(conn, scope, path, body) do
    with {:ok, depth} <- depth(conn),
         true <- Kernel.vfs_xml_request(body, "PROPFIND"),
         {:ok, entries} <- Operations.propfind(scope, path, depth) do
      entries =
        Enum.with_index(entries, fn entry, index ->
          parts = if index == 0, do: path, else: path ++ [entry.name]

          %{
            href: href(parts, Namespace.collection?(entry)),
            name: entry.name,
            collection: Namespace.collection?(entry),
            size: entry.size,
            etag: entry.etag,
            fingerprint: Map.get(entry, :fingerprint, ""),
            modified: http_date(entry.modified),
            content_type: entry.content_type,
            node_id: if(entry.node, do: entry.node.id, else: ""),
            stat_on_lookup: Map.get(entry, :stat_on_lookup, false)
          }
        end)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(207, Kernel.vfs_multistatus(entries))
    else
      {:error, reason} -> failure(conn, reason)
      false -> failure(conn, :invalid_request)
    end
  end

  defp xml_body(conn, respond) do
    case read_body(conn, length: 65_536) do
      {:ok, body, conn} -> respond.(conn, body)
      {:more, _, conn} -> failure(conn, :too_large)
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp upload_limit_header(conn) do
    {:ok, limit} = Files.Config.vfs_upload_limit()
    put_resp_header(conn, "x-ankole-upload-limit", Integer.to_string(limit))
  end

  defp refresh_body_header(conn, %{refresh_body: true}),
    do: put_resp_header(conn, "x-ankole-refresh-body", "1")

  defp refresh_body_header(conn, _), do: conn

  defp put_response(conn, scope, path, source) do
    with {:ok, headers} <- write_headers(conn),
         {:ok, node} <- Operations.put(scope, path, source, headers),
         {:ok, meta} <- put_metadata(node),
         do: conn |> metadata(meta) |> send_resp(201, ""),
         else: ({:error, reason} -> failure(conn, reason))
  end

  # The object-store writer consumes this stream in the request process. Keep
  # its latest connection even when storage stops consuming the request early.
  defp receive_object(conn, limit) do
    ref = make_ref()
    Process.put(ref, conn)

    stream =
      Stream.resource(
        fn -> {conn, limit, :more} end,
        fn
          {conn, remaining, :more} -> object_chunk(conn, remaining, ref)
          state -> {:halt, state}
        end,
        fn _ -> :ok end
      )

    try do
      result = Files.store(stream)
      {result, Process.get(ref)}
    catch
      {^ref, reason} -> {{:error, reason}, Process.get(ref)}
    after
      Process.delete(ref)
    end
  end

  defp object_chunk(conn, remaining, ref) do
    case read_body(conn, length: min(remaining + 1, 1_048_576), read_timeout: 30_000) do
      {state, bytes, next} when state in [:ok, :more] ->
        Process.put(ref, next)
        if byte_size(bytes) > remaining, do: throw({ref, :too_large})
        {[bytes], {next, remaining - byte_size(bytes), state}}

      {:error, reason} ->
        throw({ref, reason})
    end
  end

  defp receive_file(conn, path, limit) do
    with {:ok, file} <- File.open(path, [:write, :binary]) do
      try do
        receive_chunks(conn, file, limit)
      after
        File.close(file)
      end
    end
  end

  defp receive_chunks(conn, file, remaining) do
    case read_body(conn, length: min(remaining + 1, 1024 * 1024), read_timeout: 30_000) do
      {state, bytes, next} when state in [:ok, :more] and byte_size(bytes) <= remaining ->
        :ok = IO.binwrite(file, bytes)

        if state == :ok,
          do: {:ok, next},
          else: receive_chunks(next, file, remaining - byte_size(bytes))

      {_, _, next} ->
        {:error, :too_large, next}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp stream(conn, status, {:bytes, bytes}, offset, length),
    do: send_resp(conn, status, binary_part(bytes, offset, length))

  defp stream(conn, status, {:object, id, _}, offset, length) do
    conn = send_chunked(conn, status)

    Enum.reduce_while(
      Stream.unfold({offset, length}, fn
        {_, 0} ->
          nil

        {at, left} ->
          count = min(left, 1024 * 1024)
          {{at, count}, {at + count, left - count}}
      end),
      conn,
      fn {at, count}, conn ->
        with {:ok, bytes} <- Files.read_object_range(id, at, count),
             {:ok, conn} <- chunk(conn, bytes),
             do: {:cont, conn},
             else: (
               {:error, :closed} -> {:halt, conn}
               {:error, reason} -> raise "Drive object stream failed: #{inspect(reason)}"
             )
      end
    )
  end

  defp write_headers(conn) do
    headers = Map.new(conn.req_headers)

    cond do
      headers["x-ankole-request-id"] && Ecto.UUID.cast(headers["x-ankole-request-id"]) == :error ->
        {:error, :invalid_request}

      true ->
        {:ok, headers}
    end
  end

  defp range(conn, size) do
    case header(conn, "range") do
      nil ->
        {:ok, {0, size, false}}

      value ->
        case Kernel.vfs_range(value, size) do
          {offset, count} when is_integer(offset) -> {:ok, {offset, count, true}}
          _ -> {:error, :invalid_range}
        end
    end
  end

  defp depth(conn) do
    case header(conn, "depth") do
      "0" -> {:ok, 0}
      "1" -> {:ok, 1}
      _ -> {:error, :unsupported_depth}
    end
  end

  defp destination(conn) do
    uri = URI.parse(header(conn, "destination") || "")

    if (is_nil(uri.host) || uri.host == conn.host) && is_binary(uri.path) &&
         String.starts_with?(uri.path, @prefix <> "/"),
       do:
         uri.path
         |> String.replace_prefix(@prefix <> "/", "")
         |> String.split("/", trim: true)
         |> segments(),
       else: {:error, :invalid_request}
  end

  defp segments(path) do
    decoded = Enum.map(path, &URI.decode/1) |> Enum.reject(&(&1 == ""))

    if Enum.all?(decoded, fn part ->
         part not in [".", ".."] && String.valid?(part) && !String.contains?(part, ["/", <<0>>])
       end), do: {:ok, decoded}, else: {:error, :invalid_request}
  end

  defp href(path, collection?),
    do:
      @prefix <>
        "/" <>
        Enum.map_join(path, "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)) <>
        if(collection? && path != [], do: "/", else: "")

  defp header(conn, key), do: List.first(get_req_header(conn, key))
  defp put_metadata(%{node: _, etag: _} = meta), do: {:ok, meta}

  defp put_metadata(%{vfs_meta: meta} = node),
    do: {:ok, Map.put(meta, :refresh_body, Map.get(node, :vfs_refresh_body, false))}

  defp put_metadata(node) do
    with {:ok, meta} <- Content.stat(Namespace.entry(node, node.kind)),
         do: {:ok, Map.put(meta, :refresh_body, Map.get(node, :vfs_refresh_body, false))}
  end

  defp http_date(time), do: Calendar.strftime(time, "%a, %d %b %Y %H:%M:%S GMT")

  defp metadata(conn, meta),
    do:
      conn
      |> put_resp_header("etag", meta.etag)
      |> put_resp_header("x-ankole-node-id", meta.node.id)
      |> put_resp_header("x-ankole-size", Integer.to_string(meta.size))
      |> put_resp_header("x-ankole-fingerprint", Map.get(meta, :fingerprint, ""))
      |> put_resp_header("last-modified", http_date(meta.modified))
      |> put_resp_header("content-type", meta.content_type)
      |> refresh_body_header(meta)

  defp failure(conn, reason) do
    status =
      case reason do
        :unauthorized -> 401
        :invalid_request -> 400
        :not_found -> 404
        :forbidden -> 403
        :immutable_root -> 403
        :unsupported_depth -> 403
        :precondition_failed -> 412
        :name_conflict -> 412
        :invalid_range -> 416
        :too_large -> 413
        {:file_too_large, _, _} -> 413
        :not_a_directory -> 409
        :is_a_directory -> 409
        {:revision_conflict, _} -> 412
        _ -> 422
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Torque.encode!(%{error: inspect(reason)}))
  end
end
