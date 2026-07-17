defmodule Ankole.Plugins.DingTalkAdapterInboundTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias Ankole.SignalsGateway.AdapterContext
  alias DingTalkOpenAPI.Event

  defp consumer do
    context =
      AdapterContext.new(
        agent_uid: "agent-1",
        binding_name: "dingtalk",
        adapter: "dingtalk",
        user_name: "钉钉"
      )

    Inbound.chat_consumer(context, %{"platformSubjectNamespace" => "dingtalk-main"})
  end

  defp event(data) do
    %Event{type: "CALLBACK", topic: "/v1.0/im/bot/messages/get", data: data}
  end

  test "normalizes a DM text message and records the counterpart userid" do
    payload = %{
      "msgId" => "m1",
      "conversationId" => "cidA",
      "conversationType" => "1",
      "senderStaffId" => "staff1",
      "senderNick" => "Ada",
      "senderUnionId" => "union1",
      "msgtype" => "text",
      "text" => %{"content" => "hello there"},
      "createAt" => 1_700_000_000_000
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(payload), consumer())
    assert input.source_entry_id == "m1"
    assert input.source_event_id == "m1"
    assert input.signal_channel_id == "dingtalk:cidA"
    assert input.channel.kind == :im_dm
    assert input.channel.reply_mode == :channel
    assert input.channel.metadata["dm_user_id"] == "staff1"
    assert input.explicit == true
    assert input.text == "hello there"
    assert input.author["id"] == "staff1"
    assert input.author["principal_uid"] == "staff1"
    assert input.author["metadata"]["union_id"] == "union1"
    assert input.reply_to_source_entry_id == nil
    assert input.provider_thread_id == nil
  end

  test "strips the leading @-mention only when the at-list names the bot alone" do
    payload = %{
      "msgId" => "m2",
      "conversationId" => "cidG",
      "conversationType" => "2",
      "conversationTitle" => "Team",
      "senderStaffId" => "staff2",
      "senderNick" => "Bob",
      "isInAtList" => true,
      "chatbotUserId" => "bot-enc-1",
      "atUsers" => [%{"dingtalkId" => "bot-enc-1"}],
      "msgtype" => "text",
      "text" => %{"content" => "@bot  /stop"}
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(payload), consumer())
    assert input.channel.kind == :im_group
    assert input.channel.name == "Team"
    assert input.channel.metadata["dm_user_id"] == nil
    assert input.explicit == true
    assert input.text == "/stop"

    # A leading @ that could belong to another mentioned human stays intact —
    # the payload never carries the bot's display name to match against.
    mixed =
      payload
      |> Map.put("atUsers", [%{"dingtalkId" => "bot-enc-1"}, %{"staffId" => "staff9"}])
      |> Map.put("text", %{"content" => "@张三 请看看这个"})

    assert {:ok, mixed_input} = Inbound.normalize_message_receive(event(mixed), consumer())
    assert mixed_input.explicit == true
    assert mixed_input.text == "@张三 请看看这个"
  end

  test "a group message not addressed to the bot is not explicit" do
    payload = %{
      "msgId" => "m2b",
      "conversationId" => "cidG",
      "conversationType" => "2",
      "senderStaffId" => "staff2",
      "isInAtList" => false,
      "msgtype" => "text",
      "text" => %{"content" => "chatter"}
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(payload), consumer())
    assert input.explicit == false
    assert input.text == "chatter"
  end

  test "a message without senderStaffId is fail-closed" do
    payload = %{
      "msgId" => "m3",
      "conversationId" => "cid",
      "conversationType" => "1",
      "msgtype" => "text",
      "text" => %{"content" => "hi"}
    }

    assert {:ignore, :missing_platform_subject} =
             Inbound.normalize_message_receive(event(payload), consumer())
  end

  test "richText joins text segments and turns image segments into attachments" do
    payload = %{
      "msgId" => "m4",
      "conversationId" => "cid",
      "conversationType" => "1",
      "senderStaffId" => "s4",
      "msgtype" => "richText",
      "content" => %{
        "richText" => [%{"text" => "hello "}, %{"downloadCode" => "dc1"}, %{"text" => "world"}]
      }
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(payload), consumer())
    assert input.text == "hello world"
    assert [%{"download_code" => "dc1", "resource_type" => "image"}] = input.attachments
  end

  test "audio keeps the mirror text empty and rides the ASR on the attachment" do
    payload = %{
      "msgId" => "m5",
      "conversationId" => "cid",
      "conversationType" => "1",
      "senderStaffId" => "s5",
      "msgtype" => "audio",
      "recognition" => "please summarize this",
      "downloadCode" => "dc2",
      "duration" => 3000
    }

    assert {:ok, input} = Inbound.normalize_message_receive(event(payload), consumer())
    # The transcript is platform ASR, not the user's typed words — it must not
    # be mirrored as message text.
    assert input.text == nil

    assert [%{"resource_type" => "audio", "recognition" => "please summarize this"}] =
             input.attachments
  end

  test "a card callback emits a managed action with semantic dedup identity" do
    value = %{
      "version" => "ankole.interactive_output.action.v1",
      "answerKind" => "choice",
      "interactionId" => "int-1",
      "interactionVersion" => "7",
      "controlId" => "choice",
      "selectedOptionId" => "opt-a",
      "optionValue" => "a",
      "sourceActorEventId" => "evt-1"
    }

    payload = %{
      "outTrackId" => "ankole:evt-1:0",
      "openConversationId" => "cidG",
      "userId" => "staff2",
      "content" =>
        Torque.encode!(%{"cardPrivateData" => %{"actionIds" => ["opt-a"], "params" => value}})
    }

    card_event = %Event{type: "CALLBACK", topic: "/v1.0/card/instances/callback", data: payload}

    assert {:ok, input} = Inbound.normalize_card_action(card_event)
    assert input.source_entry_id == "ankole:evt-1:0"
    assert input.signal_channel_id == "dingtalk:cidG"
    # Template param passthrough may stringify integers; the adapter restores
    # the protocol's integer interactionVersion at the provider edge.
    assert input.action["value"]["interactionVersion"] == 7
    assert input.source_event_id == "card:ankole:evt-1:0:int-1:7:choice:opt-a"

    # A second press of a different option is a distinct actor event, not a
    # replay of the first.
    other =
      put_in(
        payload["content"],
        Torque.encode!(%{"cardPrivateData" => %{"params" => %{"free" => "form"}}})
      )

    assert {:ok, other_input} = Inbound.normalize_card_action(%Event{card_event | data: other})
    assert other_input.source_event_id != input.source_event_id
    assert other_input.action["value"] == %{"free" => "form"}
  end

  test "an empty text message with no attachments is ignored" do
    payload = %{
      "msgId" => "m6",
      "conversationId" => "cid",
      "conversationType" => "1",
      "senderStaffId" => "s6",
      "msgtype" => "text",
      "text" => %{"content" => "   "}
    }

    assert {:ignore, :empty_or_unsupported_message} =
             Inbound.normalize_message_receive(event(payload), consumer())
  end

  test "signal_channel_id percent-encodes the conversation id" do
    assert Inbound.signal_channel_id("cid AB/12") == "dingtalk:cid%20AB%2F12"
  end
end
