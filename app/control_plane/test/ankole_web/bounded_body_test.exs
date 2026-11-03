defmodule AnkoleWeb.BoundedBodyTest do
  use ExUnit.Case, async: true
  alias AnkoleWeb.BoundedBody

  defmodule ChunkAdapter do
    def read_req_body([part], _opts), do: {:ok, part, []}
    def read_req_body([part | rest], _opts), do: {:more, part, rest}
    def read_req_body({:error, reason}, _opts), do: {:error, reason}
  end

  test "accepts fragmented opaque bytes up to the cumulative limit" do
    conn = %Plug.Conn{adapter: {ChunkAdapter, [<<0, 255>>, "ab", "cd"]}}
    assert {:ok, <<0, 255, "abcd">>, _} = BoundedBody.read(conn, 6)
  end

  test "rejects cumulative overflow even when every fragment is small" do
    conn = %Plug.Conn{adapter: {ChunkAdapter, ["ab", "cd", "ef", "g"]}}
    assert {:error, :too_large, _} = BoundedBody.read(conn, 6)
  end

  test "accepts an exact-boundary chunk followed by an empty final chunk" do
    conn = %Plug.Conn{adapter: {ChunkAdapter, ["abcdef", ""]}}
    assert {:ok, "abcdef", _} = BoundedBody.read(conn, 6)
  end

  test "preserves transport read errors" do
    conn = %Plug.Conn{adapter: {ChunkAdapter, {:error, :timeout}}}
    assert {:error, :timeout, ^conn} = BoundedBody.read(conn, 6)
  end
end
