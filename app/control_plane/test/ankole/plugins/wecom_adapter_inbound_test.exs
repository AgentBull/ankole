defmodule Ankole.Plugins.WeComAdapterInboundTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.WeComAdapter.Inbound
  alias Ankole.SignalsGateway.AdapterContext
  alias WeComOpenAPI.Bot.Event

  defp consumer do
    context =
      AdapterContext.new(
        agent_uid: "agent-1",
        binding_name: "wecom",
        adapter: "wecom",
        user_name: "企业微信"
      )

    Inbound.chat_consumer(context, %{"platformSubjectNamespace" => "wecom-main"})
  end

  defp event(body, req_id \\ "req-1") do
    Event.from_frame(%{
      "cmd" => "aibot_msg_callback",
      "headers" => %{"req_id" => req_id},
      "body" => body
    })
  end

  test "normalizes a DM text message, records the counterpart userid and respond anchor" do
    body = %{
      "msgid" => "m1",
      "aibotid" => "bot-1",
      "chattype" => "single",
      "from" => %{"userid" => "Alice", "corpid" => "ww1"},
      "msgtype" => "text",
      "text" => %{"content" => "hello there"},
      "create_time" => 1_700_000_000
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(body, "req-dm-1"), consumer())
    assert input.source_entry_id == "m1"
    assert input.source_event_id == "m1"
    assert input.signal_channel_id == "wecom:Alice"
    assert input.channel.kind == :im_dm
    assert input.channel.metadata["dm_user_id"] == "Alice"
    assert input.channel.metadata["last_req_id"] == "req-dm-1"
    assert is_binary(input.channel.metadata["last_req_at"])
    assert input.explicit == true
    assert input.text == "hello there"
    assert input.author["id"] == "Alice"
    assert input.author["platform_subject"] == "Alice"
    refute Map.has_key?(input.author, "principal_uid")
    assert input.metadata["req_id"] == "req-dm-1"
    assert input.reply_to_source_entry_id == nil
    assert input.provider_thread_id == nil
  end

  test "a group message requires a chatid, strips one leading @-token, and is always explicit" do
    body = %{
      "msgid" => "m2",
      "chattype" => "group",
      "chatid" => "wr-group-1",
      "from" => %{"userid" => "bob"},
      "msgtype" => "text",
      "text" => %{"content" => "@AnkoleBot  /stop"}
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(body), consumer())
    assert input.channel.kind == :im_group
    assert input.signal_channel_id == "wecom:wr-group-1"
    assert input.channel.metadata["dm_user_id"] == nil
    # Groups deliver only @-mentions, so every group inbound is explicit.
    assert input.explicit == true
    assert input.text == "/stop"

    assert {:ignore, :missing_group_chatid} =
             Inbound.normalize_message_receive(
               event(Map.delete(body, "chatid")),
               consumer()
             )
  end

  test "a voice message mirrors the platform transcript as text with a metadata flag" do
    body = %{
      "msgid" => "m3",
      "chattype" => "single",
      "from" => %{"userid" => "carol"},
      "msgtype" => "voice",
      "voice" => %{"content" => "please summarize this"}
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(body), consumer())
    assert input.text == "please summarize this"
    assert input.metadata["voice_transcript"] == true
    assert input.attachments == []
  end

  test "mixed joins text segments and turns image items into encrypted attachments" do
    body = %{
      "msgid" => "m4",
      "chattype" => "single",
      "from" => %{"userid" => "dave"},
      "msgtype" => "mixed",
      "mixed" => %{
        "msg_item" => [
          %{"msgtype" => "text", "text" => %{"content" => "hello "}},
          %{"msgtype" => "image", "image" => %{"url" => "https://x/enc1", "aeskey" => "k1"}},
          %{"msgtype" => "text", "text" => %{"content" => "world"}}
        ]
      }
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(body), consumer())
    assert input.text == "hello world"

    assert [%{"resource_type" => "image", "temp_url" => "https://x/enc1", "aeskey" => "k1"}] =
             input.attachments
  end

  test "quoted text renders as a truncated leading quote block and quoted media joins attachments" do
    body = %{
      "msgid" => "m5",
      "chattype" => "single",
      "from" => %{"userid" => "erin"},
      "msgtype" => "text",
      "text" => %{"content" => "what about this?"},
      "quote" => %{
        "msgtype" => "text",
        "text" => %{"content" => "original message content"}
      }
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(body), consumer())
    assert input.text == "> 引用：original message content\n\nwhat about this?"

    long_quote = String.duplicate("很长的引用内容", 100)

    long_body =
      put_in(body, ["quote", "text", "content"], long_quote)

    assert {:ok, long_input} = Inbound.normalize_message_receive(event(long_body), consumer())
    [quote_line | _rest] = String.split(long_input.text, "\n")
    assert byte_size(quote_line) < 600
    assert String.ends_with?(quote_line, "…")

    media_quote = %{
      "msgid" => "m6",
      "chattype" => "single",
      "from" => %{"userid" => "erin"},
      "msgtype" => "text",
      "text" => %{"content" => "see quoted file"},
      "quote" => %{"msgtype" => "file", "file" => %{"url" => "https://x/f1", "aeskey" => "k2"}}
    }

    assert {:ok, media_input} = Inbound.normalize_message_receive(event(media_quote), consumer())
    assert [%{"resource_type" => "file", "temp_url" => "https://x/f1"}] = media_input.attachments
  end

  test "system senders and missing userids are fail-closed" do
    sys = %{
      "msgid" => "m7",
      "chattype" => "single",
      "from" => %{"userid" => "sys"},
      "msgtype" => "text",
      "text" => %{"content" => "callback"}
    }

    assert {:ignore, :system_sender} = Inbound.normalize_message_receive(event(sys), consumer())

    no_user = %{
      "msgid" => "m8",
      "chattype" => "single",
      "msgtype" => "text",
      "text" => %{"content" => "hi"}
    }

    assert {:ignore, :missing_platform_subject} =
             Inbound.normalize_message_receive(event(no_user), consumer())
  end

  test "an empty text message with no attachments is ignored" do
    body = %{
      "msgid" => "m9",
      "chattype" => "single",
      "from" => %{"userid" => "frank"},
      "msgtype" => "text",
      "text" => %{"content" => "   "}
    }

    assert {:ignore, :empty_or_unsupported_message} =
             Inbound.normalize_message_receive(event(body), consumer())
  end

  test "a template-card event round-trips the managed key with semantic dedup identity" do
    body = %{
      "msgid" => "evt-m1",
      "chattype" => "group",
      "chatid" => "wr-group-1",
      "from" => %{"userid" => "bob"},
      "msgtype" => "event",
      "event" => %{
        "eventtype" => "template_card_event",
        "task_id" => "ankole:actor-evt-1",
        "key" => "ank1|int-1|7|choice|opt-a|a"
      }
    }

    card_event =
      Event.from_frame(%{
        "cmd" => "aibot_event_callback",
        "headers" => %{"req_id" => "req-evt-1"},
        "body" => body
      })

    assert {:ok, input} = Inbound.normalize_card_action(card_event)
    assert input.source_entry_id == "ankole:actor-evt-1"
    assert input.signal_channel_id == "wecom:wr-group-1"
    assert input.action["value"]["interactionVersion"] == 7
    assert input.action["value"]["selectedOptionId"] == "opt-a"
    assert input.action["value"]["sourceActorEventId"] == "actor-evt-1"
    assert input.source_event_id == "card:ankole:actor-evt-1:int-1:7:choice:opt-a"

    # A foreign (unmanaged) key still produces an action with a distinct id.
    foreign = put_in(body, ["event", "key"], "custom-key")

    assert {:ok, foreign_input} =
             Inbound.normalize_card_action(%Event{card_event | body: foreign})

    assert foreign_input.action["value"] == %{
             "key" => "custom-key",
             "task_id" => "ankole:actor-evt-1"
           }

    assert foreign_input.source_event_id != input.source_event_id
  end

  test "signal_channel_id percent-encodes the chat target" do
    assert Inbound.signal_channel_id("wr AB/12") == "wecom:wr%20AB%2F12"
  end
end
