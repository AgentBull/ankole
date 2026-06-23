defmodule FeishuOpenAPI.RequestTest do
  @moduledoc """
  Tests for the request-building behavior of `FeishuOpenAPI.request/4`. Uses
  `Req.Test` to intercept requests instead of hitting the network.
  """

  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{Client, TokenStore}

  setup do
    # Skip TokenManager entirely by using :none access tokens and by pre-seeding
    # the ETS table so callers that want :tenant tokens get a deterministic value.
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set])
    end

    client =
      FeishuOpenAPI.new("cli_x", "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.RequestTest}]
      )

    put_tenant_token(client)

    on_exit(fn ->
      if :ets.info(TokenStore.table()) != :undefined do
        delete_tenant_token(client)
      end
    end)

    {:ok, client: client}
  end

  test "path template substitution + URL escaping + tenant token injection", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/open-apis/im/v1/chats/oc_x%20y"
      auth = Plug.Conn.get_req_header(conn, "authorization")
      assert auth == ["Bearer t-token"]
      Req.Test.json(conn, %{"code" => 0, "msg" => "success", "data" => %{"id" => "oc_x y"}})
    end)

    assert {:ok, %{"code" => 0, "data" => %{"id" => "oc_x y"}}} =
             FeishuOpenAPI.get(client, "/open-apis/im/v1/chats/:chat_id",
               path_params: %{chat_id: "oc_x y"}
             )
  end

  test "path params also accept keyword lists", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert conn.request_path == "/open-apis/im/v1/chats/oc_kw"
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.get(client, "/open-apis/im/v1/chats/:chat_id",
               path_params: [chat_id: "oc_kw"]
             )
  end

  test "query params are forwarded as URL parameters", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert conn.query_string == "user_id_type=open_id&page_size=20"
      Req.Test.json(conn, %{"code" => 0, "data" => []})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.get(client, "/open-apis/im/v1/chats",
               query: [user_id_type: "open_id", page_size: 20]
             )
  end

  test "body is JSON-encoded", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body) == %{"name" => "工程组", "user_id_list" => ["u1", "u2"]}
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.post(client, "/open-apis/im/v1/chats",
               body: %{name: "工程组", user_id_list: ["u1", "u2"]}
             )
  end

  test "boolean request bodies are still JSON-encoded", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body) == false
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.post(client, "/open-apis/im/v1/chats", body: false)
  end

  test "absolute URLs bypass client.base_url" do
    client =
      FeishuOpenAPI.new("cli_abs", "secret_x",
        base_url: "https://base.example.test",
        req_options: [plug: {Req.Test, FeishuOpenAPI.RequestTest}]
      )

    put_tenant_token(client)

    on_exit(fn ->
      if :ets.info(TokenStore.table()) != :undefined do
        delete_tenant_token(client)
      end
    end)

    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert conn.host == "override.example.test"
      assert conn.request_path == "/open-apis/im/v1/chats"
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.get(client, "https://override.example.test/open-apis/im/v1/chats")
  end

  test "string domains and slashless paths are normalized" do
    client =
      FeishuOpenAPI.new("cli_domain", "secret_x",
        domain: "https://domain.example.test/",
        req_options: [plug: {Req.Test, FeishuOpenAPI.RequestTest}]
      )

    put_tenant_token(client)

    on_exit(fn ->
      if :ets.info(TokenStore.table()) != :undefined do
        delete_tenant_token(client)
      end
    end)

    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert conn.host == "domain.example.test"
      assert conn.request_path == "/open-apis/im/v1/chats"
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, _} = FeishuOpenAPI.get(client, "open-apis/im/v1/chats")
  end

  test "access_token_type: nil skips Authorization", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, %{"code" => 0})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.post(client, "/open-apis/auth/v3/tenant_access_token/internal",
               body: %{app_id: "x", app_secret: "y"},
               access_token_type: nil
             )
  end

  test "user_access_token wins over token manager", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer u-explicit"]
      Req.Test.json(conn, %{"code" => 0})
    end)

    assert {:ok, _} =
             FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info",
               user_access_token: "u-explicit"
             )
  end

  test "explicit access_token_type: nil rejects conflicting user_access_token", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn _conn -> flunk("request should not be sent") end)

    assert {:error, %FeishuOpenAPI.Error{code: :conflicting_access_token_options}} =
             FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info",
               access_token_type: nil,
               user_access_token: "u-explicit"
             )
  end

  test "explicit tenant access token rejects conflicting managed user token options", %{
    client: client
  } do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn _conn -> flunk("request should not be sent") end)

    assert {:error, %FeishuOpenAPI.Error{code: :conflicting_access_token_options}} =
             FeishuOpenAPI.get(client, "/open-apis/contact/v3/users/me",
               access_token_type: :tenant_access_token,
               user_access_token_key: "current-user"
             )
  end

  test "missing path param raises a bad_path error", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn _conn -> raise "should not be called" end)

    assert {:error, %FeishuOpenAPI.Error{code: :bad_path}} =
             FeishuOpenAPI.get(client, "/open-apis/im/v1/chats/:chat_id", path_params: %{})
  end

  test "non-2xx non-envelope responses become http_error", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-tt-logid", "log-502")
      |> Plug.Conn.put_status(502)
      |> Req.Test.text("upstream unavailable")
    end)

    assert {:error,
            %FeishuOpenAPI.Error{
              code: :http_error,
              http_status: 502,
              log_id: "log-502",
              raw_body: "upstream unavailable"
            }} = FeishuOpenAPI.get(client, "/open-apis/contact/v3/users/u1")
  end

  test "non-zero response code yields a structured error", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-tt-logid", "log-abc")
      |> Req.Test.json(%{"code" => 99_999, "msg" => "something went wrong"})
    end)

    assert {:error,
            %FeishuOpenAPI.Error{
              code: 99_999,
              msg: "something went wrong",
              log_id: "log-abc"
            }} = FeishuOpenAPI.get(client, "/open-apis/contact/v3/users/u1")
  end

  test "error details and nested logid are preserved when header logid is absent", %{
    client: client
  } do
    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      Req.Test.json(conn, %{
        "code" => 44_004,
        "msg" => "permission denied",
        "error" => %{
          "logid" => "log-body",
          "permission_violations" => [%{"scope" => "contact:user.base:readonly"}]
        }
      })
    end)

    assert {:error,
            %FeishuOpenAPI.Error{
              code: 44_004,
              log_id: "log-body",
              details: %{"permission_violations" => [%{"scope" => "contact:user.base:readonly"}]}
            }} = FeishuOpenAPI.get(client, "/open-apis/contact/v3/users/u1")
  end

  test "stale-token codes do not trigger retry for access_token_type: nil (auth endpoints)",
       %{client: client} do
    # Auth endpoints and explicit-bearer requests are not SDK-managed, so
    # stale-token codes from upstream must return directly without the retry
    # that only makes sense for managed tokens.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.json(conn, %{"code" => 99_991_663, "msg" => "token invalid"})
    end)

    assert {:error, %FeishuOpenAPI.Error{code: 99_991_663}} =
             FeishuOpenAPI.post(client, "/open-apis/auth/v3/tenant_access_token/internal",
               body: %{app_id: "x", app_secret: "y"},
               access_token_type: nil
             )

    assert Agent.get(counter, & &1) == 1
  end

  test "stale-tenant-token codes invalidate the cached tenant token" do
    # Use a marketplace client with no tenant_key so the retry's token fetch
    # returns :tenant_key_required synchronously (no HTTP, no cross-process
    # stub issue). We only care that the cached token was flushed.
    client =
      FeishuOpenAPI.new("cli_mp", "secret_x",
        app_type: :marketplace,
        req_options: [plug: {Req.Test, FeishuOpenAPI.RequestTest}]
      )

    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      Req.Test.json(conn, %{"code" => 99_991_663, "msg" => "token invalid"})
    end)

    put_tenant_token(client)
    assert :ets.lookup(TokenStore.table(), tenant_key(client)) != []

    # Retry's token fetch short-circuits with an error; cache must be cleared.
    assert {:error, %FeishuOpenAPI.Error{code: :tenant_key_required}} =
             FeishuOpenAPI.get(client, "/open-apis/contact/v3/users/u1")

    assert :ets.lookup(TokenStore.table(), tenant_key(client)) == []
  end

  test "upload returns an error tuple when the file path is invalid", %{client: client} do
    assert {:error, %FeishuOpenAPI.Error{code: :bad_file}} =
             FeishuOpenAPI.upload(client, "/open-apis/im/v1/files",
               fields: [file_type: "stream"],
               file: {:path, "/definitely/missing/file.txt"}
             )
  end

  test "upload sends multipart files from a stream-backed file part", %{client: client} do
    path =
      Path.join(
        System.tmp_dir!(),
        "feishu_openapi_upload_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "streamed payload")

    on_exit(fn -> File.rm(path) end)

    Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
      assert ["multipart/form-data" <> _] = Plug.Conn.get_req_header(conn, "content-type")
      assert conn.body_params["file_type"] == "stream"
      assert %Plug.Upload{filename: "sample.txt", path: upload_path} = conn.body_params["file"]
      assert File.read!(upload_path) == "streamed payload"
      Req.Test.json(conn, %{"code" => 0, "data" => %{}})
    end)

    assert {:ok, %{"code" => 0}} =
             FeishuOpenAPI.upload(client, "/open-apis/im/v1/files",
               fields: [file_type: "stream"],
               file: {:path, path, "sample.txt"}
             )
  end

  describe "rate limiting" do
    test "HTTP 429 with x-ogw-ratelimit-reset retries after the indicated delay", %{
      client: client
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
        call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        case call do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("x-ogw-ratelimit-limit", "100")
            |> Plug.Conn.put_resp_header("x-ogw-ratelimit-reset", "0")
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{"code" => 99_991_400, "msg" => "request trigger frequency limit"})

          1 ->
            Req.Test.json(conn, %{"code" => 0, "data" => %{}})
        end
      end)

      assert {:ok, %{"code" => 0}} =
               FeishuOpenAPI.get(client, "/open-apis/im/v1/chats", access_token_type: nil)

      assert Agent.get(counter, & &1) == 2
    end

    test "HTTP 400 with body code 99991400 is treated as a legacy rate limit", %{client: client} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
        call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        case call do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("x-ogw-ratelimit-reset", "0")
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"code" => 99_991_400, "msg" => "request trigger frequency limit"})

          1 ->
            Req.Test.json(conn, %{"code" => 0, "data" => %{"ok" => true}})
        end
      end)

      assert {:ok, %{"data" => %{"ok" => true}}} =
               FeishuOpenAPI.get(client, "/open-apis/im/v1/chats", access_token_type: nil)

      assert Agent.get(counter, & &1) == 2
    end

    test "HTTP 200 with body code 99991400 is still retried as rate limited", %{client: client} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
        call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        case call do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("x-ogw-ratelimit-reset", "0")
            |> Req.Test.json(%{"code" => 99_991_400, "msg" => "request trigger frequency limit"})

          1 ->
            Req.Test.json(conn, %{"code" => 0, "data" => %{}})
        end
      end)

      assert {:ok, %{"code" => 0}} =
               FeishuOpenAPI.get(client, "/open-apis/im/v1/chats", access_token_type: nil)

      assert Agent.get(counter, & &1) == 2
    end

    test "x-ogw-ratelimit-reset wins over retry-after when both are present", %{client: client} do
      me = self()

      :telemetry.attach(
        {__MODULE__, :rl_pref, make_ref()},
        [:feishu_openapi, :request, :rate_limited],
        fn _event, _measurements, meta, _ -> send(me, {:rl, meta}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.list_handlers([:feishu_openapi, :request, :rate_limited])
        |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
        call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        case call do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "60")
            |> Plug.Conn.put_resp_header("x-ogw-ratelimit-reset", "0")
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{"code" => 99_991_400, "msg" => "rate"})

          1 ->
            Req.Test.json(conn, %{"code" => 0, "data" => %{}})
        end
      end)

      assert {:ok, _} =
               FeishuOpenAPI.get(client, "/open-apis/im/v1/chats", access_token_type: nil)

      assert_receive {:rl, %{source: :x_ogw_ratelimit_reset, http_status: 429}}, :timer.seconds(1)
    end

    test "exhausting the single rate-limit retry yields a :rate_limited error", %{client: client} do
      Req.Test.stub(FeishuOpenAPI.RequestTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ogw-ratelimit-reset", "0")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"code" => 99_991_400, "msg" => "rate"})
      end)

      assert {:error,
              %FeishuOpenAPI.Error{
                code: :rate_limited,
                http_status: 429
              }} = FeishuOpenAPI.get(client, "/open-apis/im/v1/chats", access_token_type: nil)
    end
  end

  defp put_tenant_token(client, token \\ "t-token", tenant_key \\ nil) do
    :ets.insert(TokenStore.table(), {tenant_key(client, tenant_key), token, :infinity})
  end

  defp delete_tenant_token(client, tenant_key \\ nil) do
    :ets.delete(TokenStore.table(), tenant_key(client, tenant_key))
  end

  defp tenant_key(%Client{} = client, tenant_key \\ nil) do
    {:tenant, Client.cache_namespace(client), tenant_key}
  end
end
