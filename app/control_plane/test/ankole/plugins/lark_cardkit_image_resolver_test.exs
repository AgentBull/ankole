defmodule Ankole.Plugins.LarkAdapter.CardKitImageResolverTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Plugins.LarkAdapter.CardKit.ImageResolver
  alias Ankole.Security.SSRFFilter
  alias Ankole.Conversations.Delivery.ReplyPresentation
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

  test "code examples neither fetch nor rewrite images", %{agent: agent} do
    code =
      "```markdown\n![code](https://example.com/code.png)\n```\n" <>
        "~~~\n![tilde](https://example.com/tilde.png)\n~~~\n" <>
        "`![inline](https://example.com/inline.png)` and ``![ticks](https://example.com/ticks.png)``"

    Req.default_options(plug: fn _conn -> flunk("code must not fetch an image") end)

    assert {:ok, %{"answer" => ^code}, %{}} =
             ImageResolver.resolve(%{"answer" => code}, agent.uid, %{}, :unused_client)

    url = "https://example.com/inline.png"
    state = %{url => %{"status" => "ready", "image_key" => "img_ready"}}
    mixed = code <> "\n![actual](#{url})"

    assert ImageResolver.apply_resolved(%{"answer" => mixed}, state)["answer"] ==
             code <> "\n![actual](img_ready)"
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

  test "DNS metadata and IPv4-mapped IPv6 answers are rejected before downloading", %{
    agent: agent
  } do
    dns_hosts([
      {{169, 254, 169, 254}, [~c"metadata-image.test"]},
      {{192, 0, 2, 1}, [~c"mixed-image.test"]},
      {{0, 0, 0, 0, 0, 65_535, 43_518, 43_518}, [~c"mixed-image.test"]}
    ])

    Req.default_options(plug: fn _ -> flunk("blocked DNS answers must not download") end)

    for host <- ["metadata-image.test", "mixed-image.test"] do
      url = "http://#{host}/image.png"

      assert {:ok, %{"answer" => answer}, state} =
               ImageResolver.resolve(%{"answer" => "![image](#{url})"}, agent.uid, %{}, :unused)

      assert answer == "[image](#{url})"
      assert state[url]["reason"] =~ "cloud_metadata_image_url_blocked"
    end
  end

  test "resolved private addresses follow the existing intranet setting", %{agent: agent} do
    dns_hosts([{{10, 0, 0, 8}, [~c"intranet-image.test"]}])
    url = "http://intranet-image.test/chart.png"
    presentation = %{"answer" => "![image](#{url})"}
    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, {:dialed, conn.host, Plug.Conn.get_req_header(conn, "host")})

        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "png-bytes")
      end
    )

    assert {:ok, %{"answer" => "![image](img_intranet)"}, _} =
             ImageResolver.resolve(presentation, agent.uid, %{}, upload_client("img_intranet"))

    assert_receive {:dialed, "10.0.0.8", ["intranet-image.test"]}
    assert {:ok, true} = AppConfigure.put_global(SSRFFilter.definition(), true)
    assert {:ok, _, state} = ImageResolver.resolve(presentation, agent.uid, %{}, :unused)
    assert state[url]["reason"] =~ "private_network_image_url_blocked"
    refute_receive {:dialed, _, _}
  end

  test "DNS failures and redirected metadata names degrade to links", %{agent: agent} do
    dns_hosts([{{169, 254, 169, 254}, [~c"redirected-metadata.test"]}])
    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, {:download, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", "http://redirected-metadata.test/image.png")
        |> Plug.Conn.send_resp(302, "")
      end
    )

    missing = "http://missing-image.test/image.png"

    assert {:ok, _, missing_state} =
             ImageResolver.resolve(%{"answer" => "![image](#{missing})"}, agent.uid, %{}, :unused)

    assert missing_state[missing]["reason"] =~ "image_dns_resolution_failed"
    refute_receive {:download, _}

    url = "http://127.0.0.1/redirect"

    assert {:ok, %{"answer" => answer}, state} =
             ImageResolver.resolve(%{"answer" => "![image](#{url})"}, agent.uid, %{}, :unused)

    assert_receive {:download, "/redirect"}
    refute_receive {:download, "/image.png"}
    assert answer == "[image](#{url})"
    assert state[url]["reason"] =~ "cloud_metadata_image_url_blocked"
  end

  test "the real HTTP connection stays on the checked IP after DNS changes", %{agent: agent} do
    host = "rebound-image.test"

    dns_hosts([
      {{127, 0, 0, 1}, [~c"rebound-image.test"]},
      {{169, 254, 169, 254}, [~c"before-rebind-metadata.test"]}
    ])

    parent = self()

    server =
      start_supervised!(
        {Bandit,
         ip: {127, 0, 0, 1},
         port: 0,
         plug: fn conn, _ ->
           send(parent, {:http_host, Plug.Conn.get_req_header(conn, "host")})

           conn
           |> Plug.Conn.put_resp_content_type("image/png")
           |> Plug.Conn.send_resp(200, "png-bytes")
         end}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://#{host}:#{port}/chart.png"

    Req.default_options(
      adapter: fn request ->
        assert request.url.host == "127.0.0.1"
        :inet_db.del_host({127, 0, 0, 1})
        :inet_db.add_host({169, 254, 169, 254}, [to_charlist(host)])
        Req.Finch.run(request)
      end
    )

    assert {:ok, %{"answer" => "![image](img_pinned)"}, state} =
             ImageResolver.resolve(
               %{"answer" => "![image](#{url})"},
               agent.uid,
               %{},
               upload_client("img_pinned")
             )

    assert state[url]["status"] == "ready"
    assert_receive {:http_host, [authority]}
    assert authority == "#{host}:#{port}"
    assert {:ok, [{169, 254, 169, 254}]} = :inet.getaddrs(to_charlist(host), :inet)
  end

  @tag :capture_log
  test "HTTPS uses the original hostname for SNI and certificate verification", %{agent: agent} do
    host = "tls-image.test"
    dns_hosts([{{127, 0, 0, 1}, [~c"tls-image.test", ~c"wrong-tls-image.test"]}])
    rsa = [key: {:rsa, 2048, 17}, digest: :sha256]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: to_charlist(host)]}

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: rsa, intermediates: [], peer: rsa ++ [extensions: [san]]},
        client_chain: %{root: rsa, intermediates: [], peer: rsa}
      })

    ca_path =
      Path.join(System.tmp_dir!(), "ankole-image-ca-#{System.unique_integer([:positive])}.pem")

    on_exit(fn ->
      File.rm(ca_path)
      :public_key.cacerts_clear()
      :public_key.cacerts_load()
    end)

    File.write!(
      ca_path,
      :public_key.pem_encode(
        Enum.map(certificates[:client_config][:cacerts], &{:Certificate, &1, :not_encrypted})
      )
    )

    :ok = :public_key.cacerts_load(ca_path)
    parent = self()

    transport_options =
      Keyword.take(certificates[:server_config], [:cert, :key]) ++
        [
          sni_fun: fn name ->
            send(parent, {:tls_sni, name})
            []
          end
        ]

    server =
      start_supervised!(
        {Bandit,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         thousand_island_options: [transport_options: transport_options],
         plug: fn conn, _ ->
           send(parent, {:tls_http_host, conn.host})

           conn
           |> Plug.Conn.put_resp_content_type("image/png")
           |> Plug.Conn.send_resp(200, "png-bytes")
         end}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "https://#{host}:#{port}/chart.png"

    assert {:ok, %{"answer" => "![image](img_tls)"}, _} =
             ImageResolver.resolve(
               %{"answer" => "![image](#{url})"},
               agent.uid,
               %{},
               upload_client("img_tls")
             )

    assert_receive {:tls_sni, ~c"tls-image.test"}
    assert_receive {:tls_http_host, ^host}

    wrong = "https://wrong-tls-image.test:#{port}/chart.png"

    assert {:ok, _, state} =
             ImageResolver.resolve(%{"answer" => "![image](#{wrong})"}, agent.uid, %{}, :unused)

    assert state[wrong]["status"] == "failed"
    assert state[wrong]["reason"] =~ "hostname_check_failed"
    assert_receive {:tls_sni, ~c"wrong-tls-image.test"}
    refute_receive {:tls_http_host, _}
  end

  test "the default fetch assembles streamed image chunks before upload", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://localhost/chart.png)")

    with_streamed_response(["png-", "bytes"], fn chunk_count ->
      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, upload_client("img_streamed"))

      assert :counters.get(chunk_count, 1) == 2
      assert rendered["answer"] == "![图](img_streamed)"
      assert get_in(state, ["https://localhost/chart.png", "status"]) == "ready"
    end)
  end

  test "the default fetch halts before buffering more than 20 MiB", %{agent: agent} do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://localhost/oversized.png)")

    ten_mebibytes = String.duplicate("x", 10 * 1_024 * 1_024)

    with_streamed_response([ten_mebibytes, ten_mebibytes, "overflow", "unread"], fn chunk_count ->
      assert {:ok, rendered, state} =
               ImageResolver.resolve(presentation, agent.uid, %{}, :unused_client)

      assert :counters.get(chunk_count, 1) == 3
      assert rendered["answer"] == "[图](https://localhost/oversized.png)"

      assert get_in(state, ["https://localhost/oversized.png", "reason"]) =~
               "image_too_large"
    end)
  end

  test "the default fetch degrades after one transport timeout instead of retrying", %{
    agent: agent
  } do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("![图](https://localhost/slow.png)")

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
      assert rendered["answer"] == "[图](https://localhost/slow.png)"
      assert get_in(state, ["https://localhost/slow.png", "reason"]) =~ "timeout"
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
    url = "https://localhost/chart.png"

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

  defp dns_hosts(records) do
    previous_lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file])
    Enum.each(records, fn {address, names} -> :inet_db.add_host(address, names) end)

    on_exit(fn ->
      Enum.each(records, fn {address, _} -> :inet_db.del_host(address) end)
      :inet_db.set_lookup(previous_lookup)
    end)
  end
end
