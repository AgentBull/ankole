defmodule AnkoleWeb.Plugs.AppletRouteBody do
  @moduledoc "Keeps Applet JSON values intact before the object-only browser parsers."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%{path_info: ["api", "v2", "pod", "pages", _id, "routes" | _]} = conn, _opts) do
    case AnkoleWeb.BoundedBody.read(conn, 8_000_000) do
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

      {:error, :too_large, conn} ->
        conn |> send_resp(413, "") |> halt()

      {:error, _, conn} ->
        conn |> send_resp(400, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
