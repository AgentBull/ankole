defmodule Feishu.DirectCommandTest do
  use BullX.DataCase, async: false

  alias Feishu.{DirectCommand, Source}
  alias FeishuOpenAPI.{Client, TokenManager}

  setup do
    BullX.Cache.clear()
    :ets.delete_all_objects(FeishuOpenAPI.TokenStore.table())

    on_exit(fn ->
      BullX.Cache.clear()
      :ets.delete_all_objects(FeishuOpenAPI.TokenStore.table())
    end)

    :ok
  end

  defp source_with_client do
    app_id = "cli_direct_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    client = Client.new(app_id, "secret_x", req_options: [plug: {Req.Test, __MODULE__}])

    %Source{
      id: "main",
      app_id: app_id,
      app_secret: "secret_x",
      client: client
    }
  end

  defp allow_token_manager(client) do
    {:ok, manager_pid} =
      DynamicSupervisor.start_child(FeishuOpenAPI.TokenManager.Supervisor, {TokenManager, client})

    Req.Test.allow(__MODULE__, self(), manager_pid)
  end

  test "parses slash commands" do
    assert {:ok, %{name: "root_init", args: "CODE"}} = DirectCommand.parse("/root_init CODE")
    assert {:ok, %{name: "webauth", args: ""}} = DirectCommand.parse("/webauth")
    assert :error = DirectCommand.parse("hello")
  end

  test "parses known mention text commands without treating ordinary text as commands" do
    assert {:ok, %{name: "retry", args: "", surface: "mention_text"}} =
             DirectCommand.parse_mentioned_text("retry")

    assert {:ok, %{name: "steer", args: "focus on the latest message"}} =
             DirectCommand.parse_mentioned_text("steer focus on the latest message")

    assert :error = DirectCommand.parse_mentioned_text("retry the task")
    assert :error = DirectCommand.parse_mentioned_text("hello")
  end

  test "canonicalizes localized system command aliases while keeping English commands valid" do
    assert {:ok, %{name: "status", input_name: "STATUS"}} = DirectCommand.parse("/STATUS")

    assert {:ok, %{name: "status", input_name: "状态"}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> DirectCommand.parse("/状态") end)

    assert {:ok, %{name: "command", input_name: "命令"}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> DirectCommand.parse("/命令") end)

    assert {:ok, %{name: "new", input_name: "新会话"}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> DirectCommand.parse("/新会话") end)

    assert {:ok, %{name: "status", input_name: "status"}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> DirectCommand.parse("/status") end)
  end

  test "webauth respects source-level web login disable switch" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      web_login_disabled?: true
    }

    command = %{
      event_id: "evt_webauth_disabled",
      name: "webauth",
      args: "",
      chat_id: "oc_chat",
      chat_type: "p2p",
      message_id: "om_msg",
      actor: %{id: "feishu:ou_user"},
      account_input: %{}
    }

    expected = BullX.I18n.t("im_gateway.feishu.auth.webauth_disabled")

    delivery_fun = fn delivery, _source, _opts ->
      assert get_in(delivery, ["content", Access.at(0), "body", "text"]) == expected
      {:ok, %{"delivery_id" => delivery["id"], "status" => "sent", "warnings" => []}}
    end

    assert {:ok, %{"command_name" => "webauth", "status" => "sent"}} =
             DirectCommand.handle(source, command, delivery_fun: delivery_fun)
  end

  test "root_init fetches contact user with tenant token before consuming activation code" do
    source = source_with_client()

    {:ok, %{code: code}} = BullX.Principals.create_or_refresh_bootstrap_activation_code()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/ou_user" ->
          assert conn.query_string == "user_id_type=open_id"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tenant_token"]

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "user" => %{
                "open_id" => "ou_user",
                "user_id" => "user_x",
                "name" => "Ada",
                "email" => "ADA@example.com",
                "enterprise_email" => "ADA@corp.example.com",
                "mobile" => "13800000000",
                "avatar" => %{"avatar_240" => "https://example.com/avatar.png"}
              }
            }
          })

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    command = %{
      event_id: "evt_root_init",
      name: "root_init",
      args: code,
      chat_id: "oc_chat",
      chat_type: "p2p",
      message_id: "om_msg",
      actor: %{id: "feishu:ou_user", open_id: "ou_user"},
      account_input: %{}
    }

    delivery_fun = fn delivery, _source, _opts ->
      assert get_in(delivery, ["content", Access.at(0), "body", "text"]) ==
               BullX.I18n.t("im_gateway.feishu.auth.root_init_success")

      {:ok, %{"delivery_id" => delivery["id"], "status" => "sent", "warnings" => []}}
    end

    assert {:ok, %{"command_name" => "root_init", "status" => "sent"}} =
             DirectCommand.handle(source, command, delivery_fun: delivery_fun)

    assert {:ok, principal} =
             BullX.Principals.resolve_channel_actor("feishu", "main", "feishu:ou_user")

    assert principal.display_name == "Ada"
    assert principal.uid == "ada"
    assert principal.avatar_url == "https://example.com/avatar.png"

    assert %{human_user: human_user} = BullX.Repo.preload(principal, :human_user)
    assert human_user.email == "ada@corp.example.com"
  end

  test "root_init does not consume activation code when contact user is unavailable" do
    source = source_with_client()

    {:ok, %{code: code}} = BullX.Principals.create_or_refresh_bootstrap_activation_code()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/ou_user" ->
          Req.Test.json(conn, %{"code" => 41050, "msg" => "no user authority"})

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    command = %{
      event_id: "evt_root_init_missing_userinfo",
      name: "root_init",
      args: code,
      chat_id: "oc_chat",
      chat_type: "p2p",
      message_id: "om_msg",
      actor: %{id: "feishu:ou_user", open_id: "ou_user"},
      account_input: %{}
    }

    delivery_fun = fn delivery, _source, _opts ->
      assert get_in(delivery, ["content", Access.at(0), "body", "text"]) ==
               BullX.I18n.t("im_gateway.feishu.auth.root_init_failed")

      {:ok, %{"delivery_id" => delivery["id"], "status" => "sent", "warnings" => []}}
    end

    assert {:ok, %{"command_name" => "root_init", "status" => "sent"}} =
             DirectCommand.handle(source, command, delivery_fun: delivery_fun)

    assert {:error, :not_bound} =
             BullX.Principals.resolve_channel_actor("feishu", "main", "feishu:ou_user")
  end
end
