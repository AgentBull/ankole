defmodule AnkoleWeb.PodResponse do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias Ankole.Pod.Serialization

  def respond(conn, result, encode \\ &Function.identity/1)

  def respond(conn, {:ok, result}, encode),
    do: json(conn, Serialization.json_value(encode.(result)))

  def respond(conn, {:error, reason}, _encode), do: error(conn, reason)

  @chunk_bytes 1024 * 1024

  def send_sandboxed_object(conn, object, name, type, download?) do
    type =
      case if(is_binary(type), do: Plug.Conn.Utils.media_type(type), else: :error) do
        {:ok, _, _, _} -> type
        :error -> "application/octet-stream"
      end

    inline? =
      not download? and type in ~w(image/png image/jpeg image/gif image/webp image/avif image/bmp
      application/pdf text/plain audio/mpeg audio/ogg audio/wav video/mp4 video/webm video/ogg)

    safe_name = Ankole.Files.Path.file_name(name)

    conn
    |> put_resp_content_type(type)
    |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
    |> put_resp_header("cache-control", "private, no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-disposition",
      if(inline?, do: "inline", else: "attachment") <>
        "; filename*=UTF-8''" <> URI.encode(safe_name, &URI.char_unreserved?/1)
    )
    |> send_object(object)
  end

  def send_applet_frame_asset(conn, bytes, type, sha256) do
    conn
    |> applet_headers(type)
    |> send_bytes(byte_size(bytes), sha256, fn offset, length ->
      {:ok, binary_part(bytes, offset, length)}
    end)
  end

  def send_applet_frame_object(conn, object, type) do
    conn |> applet_headers(type) |> send_object(object)
  end

  defp applet_headers(conn, type) do
    conn
    |> put_resp_content_type(type)
    |> delete_resp_header("content-security-policy")
    |> delete_resp_header("content-disposition")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("cache-control", "private, no-cache")
  end

  # A new empty file has no object until its first successful write.
  defp send_object(conn, nil) do
    digest = Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    send_bytes(conn, 0, digest, fn _, _ -> {:ok, ""} end)
  end

  defp send_object(conn, %Ankole.Files.Schemas.FileObject{} = object) do
    send_bytes(conn, object.size, Base.encode16(object.sha256, case: :lower), fn offset, length ->
      Ankole.Files.read_object_range(object, offset, length)
    end)
  end

  defp send_bytes(conn, size, digest, read) do
    etag = "\"" <> digest <> "\""
    conn = conn |> put_resp_header("accept-ranges", "bytes") |> put_resp_header("etag", etag)

    cond do
      unchanged?(conn, etag) ->
        send_resp(conn, 304, "")

      true ->
        case requested_range(conn, size, etag) do
          :unsatisfiable ->
            conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")

          selection ->
            {status, offset, length} = selection

            conn =
              if status == 206,
                do:
                  put_resp_header(
                    conn,
                    "content-range",
                    "bytes #{offset}-#{offset + length - 1}/#{size}"
                  ),
                else: conn

            send_selected(conn, status, offset, length, read)
        end
    end
  end

  defp unchanged?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn value -> String.trim(value) in ["*", etag, "W/" <> etag] end)
  end

  defp requested_range(conn, size, etag) do
    # Unsupported range units, multiple ranges, and invalid syntax are ignored.
    # If-Range requires the strong ETag for this exact immutable representation.
    with true <- get_req_header(conn, "if-range") in [[], [etag]],
         ["bytes=" <> value] <- get_req_header(conn, "range"),
         [_, first, last] <- Regex.run(~r/^(\d*)-(\d*)$/, value),
         false <- first == "" and last == "" do
      byte_range(first, last, size)
    else
      _ -> {200, 0, size}
    end
  end

  defp byte_range("", last, size) do
    length = min(String.to_integer(last), size)
    if length > 0, do: {206, size - length, length}, else: :unsatisfiable
  end

  defp byte_range(first, last, size) do
    offset = String.to_integer(first)
    ending = if last == "", do: size - 1, else: String.to_integer(last)

    cond do
      last != "" and ending < offset -> {200, 0, size}
      offset >= size -> :unsatisfiable
      true -> {206, offset, min(ending, size - 1) - offset + 1}
    end
  end

  defp send_selected(conn, status, _offset, 0, _read), do: send_resp(conn, status, "")

  defp send_selected(conn, status, offset, length, read) do
    count = min(length, @chunk_bytes)

    # Resolve the first storage read before committing the HTTP status, so a
    # missing object returns an error instead of a successful empty download.
    case read_exact(read, offset, count) do
      {:ok, bytes} ->
        conn =
          conn
          |> put_resp_header("content-length", Integer.to_string(length))
          |> send_chunked(status)

        stream(conn, bytes, offset + count, length - count, read)

      {:error, reason} ->
        conn |> delete_resp_header("content-range") |> error(reason)
    end
  end

  defp stream(conn, bytes, offset, remaining, read) do
    case chunk(conn, bytes) do
      {:ok, conn} when remaining == 0 ->
        conn

      {:ok, conn} ->
        count = min(remaining, @chunk_bytes)

        case read_exact(read, offset, count) do
          {:ok, next} -> stream(conn, next, offset + count, remaining - count, read)
          {:error, reason} -> raise "object stream failed: #{inspect(reason)}"
        end

      {:error, :closed} ->
        conn

      {:error, reason} ->
        raise "HTTP stream failed: #{inspect(reason)}"
    end
  end

  defp read_exact(read, offset, length) do
    case read.(offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :object_content_mismatch}
      {:error, _} = error -> error
    end
  end

  def error(conn, reason) do
    error = Serialization.error(reason)

    status = status(error.code)

    payload = %{error: error}

    payload =
      if error.code == "revision_conflict",
        do: Map.put(payload, :revision, error.details.revision),
        else: payload

    conn |> put_status(status) |> json(payload)
  end

  defdelegate status(code), to: Serialization
end
