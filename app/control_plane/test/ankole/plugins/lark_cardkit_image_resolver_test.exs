defmodule Ankole.Plugins.LarkAdapter.CardKitImageResolverTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Plugins.LarkAdapter.CardKit.ImageResolver
  alias Ankole.Security.SSRFFilter
  alias Ankole.SignalsGateway.ReplyPresentation

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
    :ok = SSRFFilter.ensure_registered()
    :ok = AppConfigure.delete_global(SSRFFilter.definition())
    %{principal: agent} = agent_fixture()
    %{agent: agent}
  end

  test "remote Markdown images resolve by default, including intranet URLs", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("盘中图：![走势](http://10.0.0.8/chart.png)")

    parent = self()

    fetch = fn url, ssrf_filter? ->
      send(parent, {:image_fetch, url, ssrf_filter?})
      {:ok, %{body: "png-bytes", content_type: "image/png", final_url: url}}
    end

    upload = fn :client, "png-bytes", "chart.png", "image/png" ->
      {:ok, "img_v3_chart"}
    end

    assert {:ok, rendered, state} =
             ImageResolver.resolve(presentation, agent.uid, %{}, :client,
               image_fetch_fun: fetch,
               image_upload_fun: upload
             )

    assert_receive {:image_fetch, "http://10.0.0.8/chart.png", false}
    assert rendered["answer"] == "盘中图：![走势](img_v3_chart)"
    assert get_in(state, ["http://10.0.0.8/chart.png", "status"]) == "ready"
  end

  test "security.ssrf_filter blocks private images but metadata is always blocked", %{
    agent: agent
  } do
    assert {:ok, true} = AppConfigure.put_global(SSRFFilter.definition(), true)

    upload = fn _client, _body, _filename, _content_type ->
      flunk("blocked URLs must not be uploaded")
    end

    fetch = fn _url, _ssrf_filter? ->
      flunk("blocked URLs must not be fetched")
    end

    private =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![内部](https://192.168.1.20/a.png)")

    assert {:ok, private_rendered, private_state} =
             ImageResolver.resolve(private, agent.uid, %{}, :client,
               image_fetch_fun: fetch,
               image_upload_fun: upload
             )

    assert private_rendered["answer"] == "[内部](https://192.168.1.20/a.png)"

    assert get_in(private_state, ["https://192.168.1.20/a.png", "reason"]) =~
             "private_network_image_url_blocked"

    assert {:ok, false} = AppConfigure.put_global(SSRFFilter.definition(), false)

    metadata =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![凭证](http://169.254.169.254/latest.png)")

    assert {:ok, metadata_rendered, metadata_state} =
             ImageResolver.resolve(metadata, agent.uid, %{}, :client,
               image_fetch_fun: fetch,
               image_upload_fun: upload
             )

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
      upload = fn :client, "png-bytes", "chart.png", "image/png" ->
        {:ok, "img_streamed"}
      end

      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, :client,
                 image_upload_fun: upload
               )

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
               ImageResolver.resolve(presentation, agent.uid, %{}, :client,
                 image_upload_fun: fn _client, _body, _filename, _content_type ->
                   flunk("an oversized image must not be uploaded")
                 end
               )

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
               ImageResolver.resolve(presentation, agent.uid, %{}, :client,
                 image_upload_fun: fn _client, _body, _filename, _content_type ->
                   flunk("a timed-out image must not be uploaded")
                 end
               )

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
             ImageResolver.resolve(presentation, agent.uid, state, :client,
               image_fetch_fun: fn _url, _policy -> flunk("cached image must not be fetched") end,
               image_upload_fun: fn _client, _body, _name, _type ->
                 flunk("cached image must not be uploaded")
               end
             )

    assert rendered["answer"] == "![图](img_cached)"
  end

  test "a failed image upload degrades to a link instead of an invalid image key", %{agent: agent} do
    url = "https://example.com/chart.png"

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("盘中图：![走势](#{url})")

    fetch = fn ^url, false ->
      {:ok, %{body: "png-bytes", content_type: "image/png", final_url: url}}
    end

    assert {:ok, rendered, state} =
             ImageResolver.resolve(presentation, agent.uid, %{}, :client,
               image_fetch_fun: fetch,
               image_upload_fun: fn _client, _body, _name, _type ->
                 {:error, :provider_rejected_image}
               end
             )

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
end
