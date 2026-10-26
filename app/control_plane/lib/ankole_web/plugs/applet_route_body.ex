defmodule AnkoleWeb.Plugs.AppletRouteBody do
  @moduledoc "Keeps Applet JSON values intact before the object-only browser parsers."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%{path_info: ["api", "v2", "pod", "pages", _id, "routes" | _]} = conn, _opts) do
    case read_all(conn, []) do
      {:ok, raw, conn} ->
        parsed =
          case {raw, get_req_header(conn, "content-type")} do
            {"", _} ->
              {:ok, :absent}

            {_, [type]} ->
              if match?({:ok, "application", "json", _}, Plug.Conn.Utils.media_type(type)),
                do: Torque.decode(raw),
                else: {:error, :invalid_request}

            _ ->
              {:error, :invalid_request}
          end

        conn |> put_private(:applet_route_body, parsed) |> then(&%{&1 | body_params: %{}})

      {:error, _} ->
        conn |> send_resp(400, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp read_all(conn, chunks) do
    case read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, bytes, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([bytes | chunks])), conn}
      {:more, bytes, conn} -> read_all(conn, [bytes | chunks])
      error -> error
    end
  end
end
