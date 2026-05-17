defmodule BullXWeb.CacheBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, put_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, put_raw_body(conn, body)}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_raw_body(conn, body) do
    Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> body)
  end
end
