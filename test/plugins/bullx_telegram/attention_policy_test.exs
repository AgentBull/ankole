defmodule BullxTelegram.AttentionPolicyTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.{AttentionPolicy, Source}

  defp source(overrides \\ %{}) do
    base = %Source{
      adapter: "telegram",
      channel_id: "main",
      bot_id: "100",
      bot_username: "bullx_bot",
      attention: %{
        "allowed_chat_ids" => [],
        "ignored_chat_ids" => [],
        "ignored_thread_ids" => [],
        "require_mention" => true,
        "free_response_chat_ids" => []
      }
    }

    Map.merge(base, overrides)
  end

  defp message(overrides) do
    Map.merge(
      %{
        "message_id" => 1,
        "from" => %{"id" => 999, "is_bot" => false},
        "chat" => %{"id" => -100, "type" => "supergroup"}
      },
      overrides
    )
  end

  test "private chat returns :dm" do
    assert {:ok, "dm"} =
             AttentionPolicy.message_attention(
               message(%{"chat" => %{"id" => 1, "type" => "private"}}),
               source()
             )
  end

  test "group message without mention is ignored" do
    assert {:ignore, :unmentioned_group_message} =
             AttentionPolicy.message_attention(
               message(%{"text" => "just chatting"}),
               source()
             )
  end

  test "group message mentioning bot returns :mention" do
    assert {:ok, "mention"} =
             AttentionPolicy.message_attention(
               message(%{"text" => "hey @bullx_bot what's up"}),
               source()
             )
  end

  test "direct command in group returns :command" do
    assert {:ok, "command"} =
             AttentionPolicy.message_attention(
               message(%{"text" => "/ping"}),
               source()
             )
  end

  test "command addressed to other bot is ignored" do
    assert {:ignore, :command_for_other_bot} =
             AttentionPolicy.message_attention(
               message(%{"text" => "/ping@some_other_bot"}),
               source()
             )
  end

  test "bot-authored message is ignored" do
    assert {:ignore, :bot_author} =
             AttentionPolicy.message_attention(
               message(%{"text" => "hi", "from" => %{"id" => 100, "is_bot" => true}}),
               source()
             )
  end

  test "anonymous (no from) message is ignored" do
    msg = %{
      "message_id" => 1,
      "chat" => %{"id" => -100, "type" => "supergroup"}
    }

    assert {:ignore, :anonymous_sender} = AttentionPolicy.message_attention(msg, source())
  end

  test "ignored_chat_ids overrides other rules" do
    cfg =
      source(%{
        attention: %{
          "allowed_chat_ids" => [],
          "ignored_chat_ids" => ["-100"],
          "ignored_thread_ids" => [],
          "require_mention" => true,
          "free_response_chat_ids" => []
        }
      })

    assert {:ignore, :ignored_chat} =
             AttentionPolicy.message_attention(message(%{"text" => "/ping"}), cfg)
  end

  test "free_response_chat_ids accepts unmentioned messages" do
    cfg =
      source(%{
        attention: %{
          "allowed_chat_ids" => [],
          "ignored_chat_ids" => [],
          "ignored_thread_ids" => [],
          "require_mention" => true,
          "free_response_chat_ids" => ["-100"]
        }
      })

    assert {:ok, "free_response"} =
             AttentionPolicy.message_attention(message(%{"text" => "anything"}), cfg)
  end

  test "require_mention=false treats unmentioned group as free_response" do
    cfg =
      source(%{
        attention: %{
          "allowed_chat_ids" => [],
          "ignored_chat_ids" => [],
          "ignored_thread_ids" => [],
          "require_mention" => false,
          "free_response_chat_ids" => []
        }
      })

    assert {:ok, "free_response"} =
             AttentionPolicy.message_attention(message(%{"text" => "hi"}), cfg)
  end

  test "reply to bot returns :reply_to_bot" do
    msg =
      message(%{
        "text" => "thanks",
        "reply_to_message" => %{"from" => %{"id" => 100, "is_bot" => true}}
      })

    assert {:ok, "reply_to_bot"} = AttentionPolicy.message_attention(msg, source())
  end
end
