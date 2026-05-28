defmodule Feishu.OutboundTest do
  use ExUnit.Case, async: true

  alias Feishu.{ContentMapper, Outbound, Source}

  test "materializes one stable delivery id when upstream omits it" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}
    reply_address = %{"scope_id" => "oc_chat", "reply_to_external_id" => "om_msg"}
    outbound = %{"op" => "send", "content" => [%{"kind" => "text", "body" => %{"text" => "hi"}}]}

    delivery_fun = fn delivery, _source, _opts ->
      assert is_binary(delivery["id"])
      assert delivery["id"] != ""

      {:ok,
       %{
         "delivery_id" => delivery["id"],
         "status" => "sent",
         "primary_external_id" => "om_reply",
         "warnings" => []
       }}
    end

    assert {:ok, %{"delivery_id" => delivery_id, "status" => "sent"}} =
             Outbound.deliver(source, reply_address, outbound, delivery_fun: delivery_fun)

    assert is_binary(delivery_id)
    assert delivery_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  end

  test "maps arbitrary upstream ids to Feishu UUIDs" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}
    reply_address = %{"scope_id" => "oc_chat", "reply_to_external_id" => "om_msg"}
    upstream_id = String.duplicate("a", 64)

    outbound = %{
      "id" => upstream_id,
      "op" => "send",
      "content" => [%{"kind" => "text", "body" => %{"text" => "hi"}}]
    }

    delivery_fun = fn delivery, _source, _opts ->
      refute delivery["id"] == upstream_id

      assert delivery["id"] =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      {:ok,
       %{
         "delivery_id" => delivery["id"],
         "status" => "sent",
         "primary_external_id" => "om_reply",
         "warnings" => []
       }}
    end

    assert {:ok, %{"delivery_id" => delivery_id, "status" => "sent"}} =
             Outbound.deliver(source, reply_address, outbound, delivery_fun: delivery_fun)

    assert {:ok, %{"delivery_id" => ^delivery_id}} =
             Outbound.deliver(source, reply_address, outbound, delivery_fun: delivery_fun)
  end

  test "normalizes recall deliveries with target external message id" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}
    reply_address = %{"scope_id" => "oc_chat"}
    outbound = %{"op" => "recall", "target_external_id" => "om_old"}

    delivery_fun = fn delivery, _source, _opts ->
      assert delivery["op"] == "recall"
      assert delivery["target_external_id"] == "om_old"
      assert is_binary(delivery["id"])

      {:ok, %{"delivery_id" => delivery["id"], "status" => "recalled", "warnings" => []}}
    end

    assert {:ok, %{"status" => "recalled"}} =
             Outbound.deliver(source, reply_address, outbound, delivery_fun: delivery_fun)
  end

  test "renders control notices as Feishu system dividers for direct messages" do
    notice = [
      %{
        "kind" => "control_notice",
        "body" => %{
          "text" => "Started a new conversation.",
          "short_text" => "New Session",
          "i18n" => %{"zh_CN" => "新会话", "en_US" => "New Session"}
        }
      }
    ]

    assert {:ok, rendered, []} = ContentMapper.render_outbound(notice, nil, scope_kind: "dm")

    assert rendered.msg_type == "system"
    assert {:ok, content} = Jason.decode(rendered.content)
    assert content["type"] == "divider"
    assert get_in(content, ["params", "divider_text", "text"]) == "New Session"
    assert get_in(content, ["params", "divider_text", "i18n_text", "zh_CN"]) == "新会话"
    assert get_in(content, ["options", "need_rollup"]) == true
  end

  test "renders control notices as compact cards outside p2p scopes" do
    notice = %{
      "kind" => "control_notice",
      "body" => %{"text" => "Started a new conversation.", "short_text" => "New Session"}
    }

    assert {:ok, rendered, []} =
             ContentMapper.render_outbound(notice, nil, scope_kind: "group")

    assert rendered.msg_type == "interactive"
    assert {:ok, card} = Jason.decode(rendered.content)
    assert card["schema"] == "2.0"
    assert get_in(card, ["config", "update_multi"]) == true
    assert get_in(card, ["body", "elements", Access.at(0), "tag"]) == "div"

    assert get_in(card, ["body", "elements", Access.at(0), "text", "content"]) ==
             "Started a new conversation."
  end

  test "renders progress notices as updateable compact cards" do
    started = %{
      "kind" => "progress_notice",
      "body" => %{"text" => "正在压缩历史对话...", "show_divider" => false}
    }

    finished = %{
      "kind" => "progress_notice",
      "body" => %{"text" => "以上历史对话记录已被压缩", "show_divider" => true}
    }

    assert {:ok, started_rendered, []} = ContentMapper.render_outbound(started, nil)
    assert started_rendered.msg_type == "interactive"
    assert {:ok, started_card} = Jason.decode(started_rendered.content)

    assert get_in(started_card, ["body", "elements", Access.at(0), "text", "content"]) ==
             "正在压缩历史对话..."

    assert {:ok, finished_rendered, []} = ContentMapper.render_outbound(finished, nil)
    assert finished_rendered.msg_type == "interactive"
    assert {:ok, finished_card} = Jason.decode(finished_rendered.content)
    assert get_in(finished_card, ["body", "elements", Access.at(0), "tag"]) == "hr"

    assert get_in(finished_card, ["body", "elements", Access.at(1), "text", "content"]) ==
             "以上历史对话记录已被压缩"
  end
end
