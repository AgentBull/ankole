defmodule Ankole.Plugins.MarkdownCodeProtectionTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DingTalkAdapter.Markdown, as: DingTalk
  alias Ankole.Plugins.WeComAdapter.Markdown, as: WeCom
  alias Ankole.Plugins.Microsoft365Adapter.Markdown, as: Teams
  alias Ankole.Plugins.Microsoft365Adapter.{Conversations, Outbox}
  alias Ankole.SignalsGateway.OutboxEntry

  @converters [{DingTalk, :to_dingtalk}, {WeCom, :to_wecom}, {Teams, :from_markdown}]

  test "original fenced and inline code bytes survive every converter" do
    examples = [
      "```yaml\n---\n<div>\n- [x] literal\n![image](https://x)\n| a | b |\n| - | - |\n| 1 | 2 |\n```",
      "````\n```\n~~~~\nVec<String>\n````",
      "~~~rust\n```\nVec<String>\n~~~",
      "> ```\n> <div>\n> - [x] literal\n> ```",
      "    Vec<String>\n    - [x] literal",
      "    ---\n    <div>\n    - [x] literal\n",
      "\tVec<String>\r\n\t---\r\n",
      ">     <div>\n>     ---\n",
      "- ```\n  <div>\n  ---\n  ```",
      "```unclosed\n---\n<div>\n",
      "中文 `Vec<String>` and ``a`b`` and `![image](https://x)`",
      "中文 `first\r\n  <span> second` tail",
      "```yaml\r\n---\r\n<div>\r\n```",
      "~~~\r---\r<div>\r~~~",
      "`\0ankole-code-0\0 <div>` and \0ankole-code-0\0"
    ]

    for {module, function} <- @converters, code <- examples do
      assert apply(module, function, [code]) == code,
             "#{inspect(module)} changed #{inspect(code)}"
    end
  end

  test "a marker already present in the original source is not substituted" do
    marker = <<0, ?0, ?X>>
    source = "#{marker} and `#{marker}<div>` and `<x>`"

    for {module, function} <- @converters do
      assert apply(module, function, [source]) == source
    end
  end

  test "partial markers and prose rewrites cannot collide with code markers" do
    prefix = <<0, ?0>>
    source = prefix <> "`Vec<String>`"

    for {module, function} <- @converters do
      assert apply(module, function, [source]) == source
    end

    source = "\0<b>0</b>X `Vec<String>`"

    for {module, function} <- [{DingTalk, :to_dingtalk}, {WeCom, :to_wecom}] do
      assert apply(module, function, [source]) == "\00X `Vec<String>`"
    end

    assert Teams.from_markdown(source) == source
  end

  test "prose tables keep context around inline pipe and HTML code" do
    table = "| a | b |\n| - | - |\n| `x|y` | `<br>` |\n"
    assert DingTalk.to_dingtalk(table) == "```\n#{String.trim_trailing(table)}\n```\n"
    assert WeCom.to_wecom(table) == table
    assert Teams.from_markdown(table) == "a · b\n\n`x|y` · `<br>`\n"
  end

  test "prose lowering remains active next to protected code" do
    source = "keep <b>bold</b>\n- [x] done\n\n```\n<div>\n- [x] literal\n```\n"
    expected = "keep bold\n- done\n\n```\n<div>\n- [x] literal\n```\n"
    assert DingTalk.to_dingtalk(source) == expected
    assert WeCom.to_wecom(source) == expected
    assert Teams.from_markdown(source) == source

    assert WeCom.to_wecom("![outside](https://x) and `![inside](https://y)`") ==
             "[图片: outside](https://x) and `![inside](https://y)`"
  end

  test "HTML-like prose cannot remove an embedded code marker" do
    for {module, function} <- [{DingTalk, :to_dingtalk}, {WeCom, :to_wecom}] do
      assert apply(module, function, ["<tag `Vec<String>` >"]) == "`Vec<String>`"
      assert apply(module, function, ["<tag `first` `second` >"]) == "`first``second`"
    end
  end

  test "Teams converts full text once before source-lossless paging for reply and edit" do
    code = "```yaml\n" <> String.duplicate("a", 12_000) <> "\n---\nkind: Service\n```"
    source = "---\n" <> code
    target = %{conversation_id: "19:room@thread.tacv2", channel?: true}

    entry = %OutboxEntry{
      operation: :reply,
      fallback_visible_text: source,
      reply_to_source_entry_id: "root-1",
      provider_thread_id: Conversations.provider_thread_id(target.conversation_id, "root-1"),
      target_source_entry_id: "existing-preview"
    }

    for operation <- [:reply, :edit] do
      assert {:ok, requests} = Outbox.requests_for_outbox(%{entry | operation: operation}, target)
      assert Enum.map_join(requests, & &1.activity["text"]) == "———\n" <> code
      assert Enum.all?(requests, &(String.length(&1.activity["text"]) <= 12_000))
      assert Enum.all?(requests, &(&1.conversation_id == "19:room@thread.tacv2;messageid=root-1"))

      if operation == :edit do
        assert hd(requests).kind == :update
        assert hd(requests).activity_id == "existing-preview"
      end
    end
  end
end
