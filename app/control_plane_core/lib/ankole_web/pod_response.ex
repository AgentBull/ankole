defmodule AnkoleWeb.PodResponse do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias Ankole.Pod.Serialization

  def respond(conn, result, encode \\ &Function.identity/1)

  def respond(conn, {:ok, result}, encode),
    do: json(conn, Serialization.json_value(encode.(result)))

  def respond(conn, {:error, reason}, _encode), do: error(conn, reason)

  def send_sandboxed_file(conn, local, name, type, download?) do
    type =
      case if(is_binary(type), do: Plug.Conn.Utils.media_type(type), else: :error) do
        {:ok, _, _, _} -> type
        :error -> "application/octet-stream"
      end

    inline? =
      not download? and type in ~w(image/png image/jpeg image/gif image/webp image/avif image/bmp
      application/pdf text/plain audio/mpeg audio/ogg audio/wav video/mp4 video/webm video/ogg)

    conn
    |> put_resp_content_type(type)
    |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
    |> put_resp_header("cache-control", "private, no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-disposition",
      if(inline?, do: "inline", else: "attachment") <>
        "; filename*=UTF-8''" <> URI.encode(name, &URI.char_unreserved?/1)
    )
    |> send_file(200, local)
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
