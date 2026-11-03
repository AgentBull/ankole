defmodule AnkoleWeb.BoundedBody do
  @moduledoc "Reads an opaque request body within a cumulative byte limit."

  def read(conn, limit), do: read(conn, limit, [])

  defp read(conn, remaining, chunks) do
    case Plug.Conn.read_body(conn, length: remaining + 1, read_length: 64 * 1024) do
      {status, bytes, conn} when status in [:ok, :more] ->
        cond do
          byte_size(bytes) > remaining -> {:error, :too_large, conn}
          status == :ok -> {:ok, IO.iodata_to_binary(Enum.reverse([bytes | chunks])), conn}
          true -> read(conn, remaining - byte_size(bytes), [bytes | chunks])
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end
end
