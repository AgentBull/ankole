defmodule BullXTelegram.AttentionPolicyTest do
  use ExUnit.Case, async: true

  alias BullXTelegram.{AttentionPolicy, Config}

  test "accepts DMs, bot-qualified commands, mentions, replies, and free-response chats" do
    config = config()

    assert {:ok, "dm"} =
             AttentionPolicy.message_attention(message(%{"chat" => private_chat()}), config)

    assert {:ok, "command"} =
             AttentionPolicy.message_attention(message(%{"text" => "/ask@BullXBot hi"}), config)

    assert {:ok, "mention"} =
             AttentionPolicy.message_attention(message(%{"text" => "hello @BullXBot"}), config)

    assert {:ok, "reply_to_bot"} =
             AttentionPolicy.message_attention(
               message(%{"reply_to_message" => %{"from" => %{"id" => 999, "is_bot" => true}}}),
               config
             )

    config = put_in(config.attention.free_response_chat_ids, ["200"])
    assert {:ok, "free_response"} = AttentionPolicy.message_attention(message(%{}), config)
  end

  test "rejects ignored chats topics and unaddressed groups" do
    config = config()

    assert {:ignore, :unmentioned_group_message} =
             AttentionPolicy.message_attention(message(%{}), config)

    config = put_in(config.attention.ignored_chat_ids, ["200"])
    assert {:ignore, :ignored_chat} = AttentionPolicy.message_attention(message(%{}), config)

    config = config() |> put_in([Access.key!(:attention), :ignored_thread_ids], ["77"])

    assert {:ignore, :ignored_thread} =
             AttentionPolicy.message_attention(message(%{"message_thread_id" => 77}), config)
  end

  test "ignores commands qualified for another bot" do
    assert {:ignore, :unsupported_command} =
             AttentionPolicy.message_attention(message(%{"text" => "/ask@OtherBot hi"}), config())
  end

  test "ignores unsupported slash commands in groups" do
    assert {:ignore, :unsupported_command} =
             AttentionPolicy.message_attention(message(%{"text" => "/unknown hi"}), config())
  end

  defp config do
    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        bot_username: "BullXBot",
        bot_id: "999"
      })

    config
  end

  defp message(attrs) do
    Map.merge(
      %{
        "message_id" => 10,
        "chat" => %{"id" => 200, "type" => "group"},
        "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false},
        "text" => "hello"
      },
      attrs
    )
  end

  defp private_chat, do: %{"id" => 200, "type" => "private"}
end
