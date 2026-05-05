defmodule FeishuOpenAPI.UserTokenManagerTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.UserTokenManager

  setup do
    ensure_started(UserTokenManager)

    unique = System.unique_integer([:positive])

    client =
      FeishuOpenAPI.new("cli_user_#{unique}", "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.UserTokenManagerTest}]
      )

    {:ok, client: client, user_key: "user_#{unique}"}
  end

  test "missing managed user token returns a structured error", %{
    client: client,
    user_key: user_key
  } do
    assert {:error, %FeishuOpenAPI.Error{code: :user_token_missing}} =
             UserTokenManager.get(client, user_key)
  end

  test "get/2 refreshes an expired managed user token", %{client: client, user_key: user_key} do
    parent = self()

    :ok =
      UserTokenManager.put(client, user_key, %{
        access_token: "u-old",
        refresh_token: "refresh_x",
        token_type: "Bearer",
        expires_in: 1,
        refresh_expires_in: 2_592_000,
        scope: "contact:user.base:readonly",
        raw: %{}
      })

    Req.Test.stub(FeishuOpenAPI.UserTokenManagerTest, fn conn ->
      assert conn.request_path == "/open-apis/authen/v2/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:refresh_body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "access_token" => "u-new",
          "refresh_token" => "refresh_new",
          "token_type" => "Bearer",
          "expires_in" => 7200,
          "refresh_expires_in" => 2_592_000
        }
      })
    end)

    :ok =
      Req.Test.allow(
        FeishuOpenAPI.UserTokenManagerTest,
        self(),
        Process.whereis(UserTokenManager)
      )

    assert {:ok, "u-new"} = UserTokenManager.get(client, user_key)

    assert_received {:refresh_body,
                     %{"grant_type" => "refresh_token", "refresh_token" => "refresh_x"}}

    assert {:ok, "u-new"} = UserTokenManager.get(client, user_key)
    refute_received {:refresh_body, _}
  end

  test "request/4 injects refreshed managed user tokens", %{client: client, user_key: user_key} do
    :ok =
      UserTokenManager.put(client, user_key, %{
        access_token: "u-old",
        refresh_token: "refresh_req",
        token_type: "Bearer",
        expires_in: 1,
        refresh_expires_in: 2_592_000,
        raw: %{}
      })

    Req.Test.stub(FeishuOpenAPI.UserTokenManagerTest, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "access_token" => "u-request",
              "refresh_token" => "refresh_req_new",
              "token_type" => "Bearer",
              "expires_in" => 7200,
              "refresh_expires_in" => 2_592_000
            }
          })

        "/open-apis/authen/v1/user_info" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer u-request"]
          Req.Test.json(conn, %{"code" => 0, "data" => %{"user_id" => "ou_xxx"}})

        other ->
          flunk("unexpected request path: #{other}")
      end
    end)

    :ok =
      Req.Test.allow(
        FeishuOpenAPI.UserTokenManagerTest,
        self(),
        Process.whereis(UserTokenManager)
      )

    assert {:ok, %{"code" => 0, "data" => %{"user_id" => "ou_xxx"}}} =
             FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info",
               user_access_token_key: user_key
             )
  end

  test "concurrent expired-token callers on the same key share a single upstream refresh", %{
    client: client,
    user_key: user_key
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    :ok =
      UserTokenManager.put(client, user_key, %{
        access_token: "u-old",
        refresh_token: "refresh_dedup",
        token_type: "Bearer",
        expires_in: 1,
        refresh_expires_in: 2_592_000,
        raw: %{}
      })

    Req.Test.stub(FeishuOpenAPI.UserTokenManagerTest, fn conn ->
      assert conn.request_path == "/open-apis/authen/v2/oauth/token"
      Agent.update(counter, &(&1 + 1))
      Process.sleep(150)

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "access_token" => "u-dedup",
          "refresh_token" => "refresh_dedup_new",
          "token_type" => "Bearer",
          "expires_in" => 7200,
          "refresh_expires_in" => 2_592_000
        }
      })
    end)

    :ok =
      Req.Test.allow(
        FeishuOpenAPI.UserTokenManagerTest,
        self(),
        Process.whereis(UserTokenManager)
      )

    tasks =
      for _ <- 1..20 do
        Task.async(fn -> UserTokenManager.get(client, user_key) end)
      end

    results = Enum.map(tasks, &Task.await(&1, :timer.seconds(5)))

    assert Enum.all?(results, &match?({:ok, "u-dedup"}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  test "refresh task start failures return a structured error and do not wedge the key", %{
    client: client,
    user_key: user_key
  } do
    previous =
      Application.get_env(:feishu_openapi, :user_token_manager_task_supervisor, :__missing__)

    Application.put_env(
      :feishu_openapi,
      :user_token_manager_task_supervisor,
      FeishuOpenAPI.MissingTaskSupervisor
    )

    on_exit(fn ->
      case previous do
        :__missing__ ->
          Application.delete_env(:feishu_openapi, :user_token_manager_task_supervisor)

        value ->
          Application.put_env(:feishu_openapi, :user_token_manager_task_supervisor, value)
      end
    end)

    :ok =
      UserTokenManager.put(client, user_key, %{
        access_token: "u-old",
        refresh_token: "refresh_fail",
        token_type: "Bearer",
        expires_in: 1,
        refresh_expires_in: 2_592_000,
        raw: %{}
      })

    assert {:error, %FeishuOpenAPI.Error{code: :user_refresh_start_failed}} =
             UserTokenManager.get(client, user_key)

    assert {:error, %FeishuOpenAPI.Error{code: :user_refresh_start_failed}} =
             UserTokenManager.get(client, user_key)
  end

  test "concurrent refreshes on different keys proceed in parallel", %{client: client} do
    parent = self()
    keys = for i <- 1..5, do: "user_par_#{i}"

    for user_key <- keys do
      :ok =
        UserTokenManager.put(client, user_key, %{
          access_token: "u-old-#{user_key}",
          refresh_token: "refresh-#{user_key}",
          token_type: "Bearer",
          expires_in: 1,
          refresh_expires_in: 2_592_000,
          raw: %{}
        })
    end

    Req.Test.stub(FeishuOpenAPI.UserTokenManagerTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body_map = Jason.decode!(body)
      refresh_token = body_map["refresh_token"]
      send(parent, {:refresh_started, refresh_token, System.monotonic_time(:millisecond)})
      Process.sleep(200)

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "access_token" => "u-new-#{refresh_token}",
          "refresh_token" => refresh_token,
          "token_type" => "Bearer",
          "expires_in" => 7200,
          "refresh_expires_in" => 2_592_000
        }
      })
    end)

    :ok =
      Req.Test.allow(
        FeishuOpenAPI.UserTokenManagerTest,
        self(),
        Process.whereis(UserTokenManager)
      )

    started =
      keys
      |> Enum.map(fn user_key ->
        Task.async(fn -> UserTokenManager.get(client, user_key) end)
      end)
      |> Enum.map(&Task.await(&1, :timer.seconds(5)))

    # All calls succeeded.
    assert Enum.all?(started, &match?({:ok, _}, &1))

    # Collect refresh-start timestamps; five keys should all start within a narrow
    # window (well under the 200ms sleep × 5 = 1000ms that serial refresh would need).
    start_times =
      for _ <- 1..5 do
        assert_receive {:refresh_started, _rt, ts}, :timer.seconds(2)
        ts
      end

    spread = Enum.max(start_times) - Enum.min(start_times)
    assert spread < 150, "expected parallel starts, got spread=#{spread}ms"
  end

  defp ensure_started(module) do
    if Process.whereis(module) == nil do
      start_supervised!(module)
    end
  end
end
