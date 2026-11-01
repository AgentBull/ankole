defmodule AnkoleWeb.PodResponseTest do
  use Ankole.DataCase, async: true
  import Plug.Conn
  alias Ankole.{Files, ObjectStore}
  alias AnkoleWeb.PodResponse

  setup do
    {:ok, stored} = Files.store("0123456789")
    {:ok, object} = Repo.transact_top_level(fn -> Files.complete_object_in_tx(stored) end)
    %{object: object}
  end

  defp serve(object, headers \\ []) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, "/file"), fn {key, value}, conn ->
        put_req_header(conn, key, value)
      end)

    PodResponse.send_sandboxed_object(conn, object, "file.txt", "text/plain", false)
  end

  test "closed, open, and suffix ranges use the exact immutable bytes", %{object: object} do
    for {range, bytes, content_range} <- [
          {"bytes=2-5", "2345", "bytes 2-5/10"},
          {"bytes=6-", "6789", "bytes 6-9/10"},
          {"bytes=-3", "789", "bytes 7-9/10"},
          {"bytes=8-100", "89", "bytes 8-9/10"}
        ] do
      conn = serve(object, [{"range", range}])
      assert conn.status == 206
      assert conn.resp_body == bytes
      assert get_resp_header(conn, "content-length") == [Integer.to_string(byte_size(bytes))]
      assert get_resp_header(conn, "content-range") == [content_range]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end
  end

  test "unsatisfiable and empty file ranges return 416", %{object: object} do
    for range <- ["bytes=10-", "bytes=-0"] do
      conn = serve(object, [{"range", range}])
      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */10"]
    end

    assert serve(nil).resp_body == ""
    assert serve(nil).status == 200
    empty = serve(nil, [{"range", "bytes=0-"}])
    assert empty.status == 416
    assert get_resp_header(empty, "content-range") == ["bytes */0"]
  end

  test "conditional requests compare the frozen representation, not a mutable path", %{
    object: object
  } do
    [etag] = serve(object) |> get_resp_header("etag")
    assert serve(object, [{"range", "bytes=1-2"}, {"if-range", etag}]).status == 206
    full = serve(object, [{"range", "bytes=1-2"}, {"if-range", "\"older-object\""}])
    assert full.status == 200
    assert full.resp_body == "0123456789"
    cached = serve(object, [{"range", "bytes=100-"}, {"if-none-match", "W/" <> etag}])
    assert cached.status == 304
    assert cached.resp_body == ""
  end

  test "unsupported and malformed ranges fall back to the complete representation", %{
    object: object
  } do
    for range <- ["items=1-2", "bytes=1-2,4-5", "bytes=oops", "bytes=7-2"] do
      conn = serve(object, [{"range", range}])
      assert conn.status == 200
      assert conn.resp_body == "0123456789"
    end
  end

  test "large responses stream across storage chunks and missing objects fail before 200" do
    bytes = :binary.copy("range", 500_000)
    {:ok, stored} = Files.store(bytes)
    {:ok, object} = Repo.transact_top_level(fn -> Files.complete_object_in_tx(stored) end)
    assert serve(object).resp_body == bytes
    assert :ok = ObjectStore.delete(object.storage_key)
    missing = serve(object)
    assert missing.status == 404
    assert Jason.decode!(missing.resp_body)["error"]["code"] == "not_found"
  end
end
