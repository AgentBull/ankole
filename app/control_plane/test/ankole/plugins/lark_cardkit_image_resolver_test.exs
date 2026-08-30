defmodule Ankole.Plugins.LarkAdapter.CardKitImageResolverTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Plugins.LarkAdapter.CardKit.ImageResolver
  alias Ankole.Security.SSRFFilter
  alias Ankole.SignalsGateway.ReplyPresentation
  alias FeishuOpenAPI.Client

  setup do
    Req.Test.set_req_test_to_shared()
    Registry.clear_for_test()
    Cache.clear_for_test()
    :ok = AppConfigure.delete_global(SSRFFilter.definition())
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    %{principal: agent} = agent_fixture()
    %{agent: agent}
  end

  test "remote Markdown images resolve by default, including intranet URLs", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("盘中图：![走势](http://10.0.0.8/chart.png)")

    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, {:image_fetch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "png-bytes")
      end
    )

    assert {:ok, rendered, state} =
             ImageResolver.resolve(presentation, agent.uid, %{}, upload_client("img_v3_chart"))

    assert_receive {:image_fetch, "/chart.png"}
    assert rendered["answer"] == "盘中图：![走势](img_v3_chart)"
    assert get_in(state, ["http://10.0.0.8/chart.png", "status"]) == "ready"
  end

  test "security.ssrf_filter blocks private images but metadata is always blocked", %{
    agent: agent
  } do
    assert {:ok, true} = AppConfigure.put_global(SSRFFilter.definition(), true)

    private =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![内部](https://192.168.1.20/a.png)")

    assert {:ok, private_rendered, private_state} =
             ImageResolver.resolve(private, agent.uid, %{}, :unused_client)

    assert private_rendered["answer"] == "[内部](https://192.168.1.20/a.png)"

    assert get_in(private_state, ["https://192.168.1.20/a.png", "reason"]) =~
             "private_network_image_url_blocked"

    assert {:ok, false} = AppConfigure.put_global(SSRFFilter.definition(), false)

    metadata =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![凭证](http://169.254.169.254/latest.png)")

    assert {:ok, metadata_rendered, metadata_state} =
             ImageResolver.resolve(metadata, agent.uid, %{}, :unused_client)

    assert metadata_rendered["answer"] ==
             "[凭证](http://169.254.169.254/latest.png)"

    assert get_in(metadata_state, ["http://169.254.169.254/latest.png", "reason"]) =~
             "cloud_metadata_image_url_blocked"
  end

  test "the default fetch assembles streamed image chunks before upload", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://example.com/chart.png)")

    with_streamed_response(["png-", "bytes"], fn chunk_count ->
      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, upload_client("img_streamed"))

      assert :counters.get(chunk_count, 1) == 2
      assert rendered["answer"] == "![图](img_streamed)"
      assert get_in(state, ["https://example.com/chart.png", "status"]) == "ready"
    end)
  end

  test "the default fetch halts before buffering more than 20 MiB", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://example.com/oversized.png)")

    ten_mebibytes = String.duplicate("x", 10 * 1_024 * 1_024)

    with_streamed_response([ten_mebibytes, ten_mebibytes, "overflow", "unread"], fn chunk_count ->
      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, :unused_client)

      assert :counters.get(chunk_count, 1) == 3
      assert rendered["answer"] == "[图](https://example.com/oversized.png)"

      assert get_in(state, ["https://example.com/oversized.png", "reason"]) =~
               "image_too_large"
    end)
  end

  test "the default fetch degrades after one transport timeout instead of retrying", %{
    agent: agent
  } do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://example.com/slow.png)")

    previous_options = Req.default_options()
    attempts = :counters.new(1, [])

    finch_request = fn request, _finch_request, _finch_name, _finch_options ->
      :counters.add(attempts, 1, 1)
      {request, Req.TransportError.exception(reason: :timeout)}
    end

    Req.default_options(Keyword.put(previous_options, :finch_request, finch_request))

    try do
      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, :unused_client)

      assert :counters.get(attempts, 1) == 1
      assert rendered["answer"] == "[图](https://example.com/slow.png)"
      assert get_in(state, ["https://example.com/slow.png", "reason"]) =~ "timeout"
    after
      Req.default_options(previous_options)
    end
  end

  test "a persisted image resolution is reused without fetching again", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://example.com/a.png)")

    state = %{
      "https://example.com/a.png" => %{
        "status" => "ready",
        "image_key" => "img_cached"
      }
    }

    assert {:ok, rendered, ^state} =
             ImageResolver.resolve(presentation, agent.uid, state, :unused_client)

    assert rendered["answer"] == "![图](img_cached)"
  end

  test "a failed image upload degrades to a link instead of an invalid image key", %{agent: agent} do
    url = "https://example.com/chart.png"

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("盘中图：![走势](#{url})")

    Req.default_options(
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "png-bytes")
      end
    )

    assert {:ok, rendered, state} =
             ImageResolver.resolve(presentation, agent.uid, %{}, upload_client(nil))

    assert rendered["answer"] == "盘中图：[走势](#{url})"
    assert get_in(state, [url, "status"]) == "failed"
  end

  defp with_streamed_response(chunks, fun) do
    previous_options = Req.default_options()
    chunk_count = :counters.new(1, [])

    finch_request = fn request, _finch_request, _finch_name, _finch_options ->
      response =
        Req.Response.new(status: 200)
        |> Req.Response.put_header("content-type", "image/png")

      Enum.reduce_while(chunks, {request, response}, fn chunk, {request, _response} = acc ->
        :counters.add(chunk_count, 1, 1)

        case request.into.({:data, chunk}, acc) do
          {:cont, acc} -> {:cont, acc}
          {:halt, acc} -> {:halt, acc}
        end
      end)
    end

    Req.default_options(Keyword.put(previous_options, :finch_request, finch_request))

    try do
      fun.(chunk_count)
    after
      Req.default_options(previous_options)
    end
  end

  defp upload_client(image_key) do
    Client.new("cli_image_resolver", fn -> "secret" end,
      domain: :feishu,
      req_options: [
        plug: fn conn ->
          case conn.request_path do
            "/open-apis/auth/v3/tenant_access_token/internal" ->
              Req.Test.json(conn, %{
                "code" => 0,
                "tenant_access_token" => "tenant-token",
                "expire" => 7_200
              })

            "/open-apis/im/v1/images" when is_binary(image_key) ->
              Req.Test.json(conn, %{"code" => 0, "data" => %{"image_key" => image_key}})

            "/open-apis/im/v1/images" ->
              Req.Test.json(conn, %{"code" => 999, "msg" => "upload rejected"})
          end
        end
      ]
    )
  end
end
