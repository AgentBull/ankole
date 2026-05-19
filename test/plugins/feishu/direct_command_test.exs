defmodule Feishu.DirectCommandTest do
  use ExUnit.Case, async: false

  alias Feishu.{DirectCommand, Source}

  setup do
    BullX.Cache.clear()
    on_exit(fn -> BullX.Cache.clear() end)
    :ok
  end

  test "parses slash commands" do
    assert {:ok, %{name: "preauth", args: "CODE"}} = DirectCommand.parse("/preauth CODE")
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

    expected = BullX.I18n.t("eventbus.feishu.auth.webauth_disabled")

    delivery_fun = fn delivery, _source, _opts ->
      assert get_in(delivery, ["content", Access.at(0), "body", "text"]) == expected
      {:ok, %{"delivery_id" => delivery["id"], "status" => "sent", "warnings" => []}}
    end

    assert {:ok, %{"command_name" => "webauth", "status" => "sent"}} =
             DirectCommand.handle(source, command, delivery_fun: delivery_fun)
  end
end
