defmodule Discord.AttentionPolicyTest do
  use ExUnit.Case, async: true

  alias Discord.{AttentionPolicy, Source}

  defp source(overrides \\ %{}) do
    base = %{
      adapter: "discord",
      channel_id: "main",
      bot_user_id: "9999",
      attention: %{
        "allowed_channel_ids" => [],
        "ignored_channel_ids" => [],
        "ignored_thread_ids" => [],
        "require_mention" => true,
        "free_response_channel_ids" => []
      }
    }

    struct!(Source, Map.merge(base, overrides))
  end

  describe "message_attention/2" do
    test "DM returns dm" do
      message = %{"channel_id" => "1", "guild_id" => nil, "content" => "hi"}
      assert {:ok, "dm"} = AttentionPolicy.message_attention(message, source())
    end

    test "mention in guild returns mention" do
      message = %{
        "channel_id" => "1",
        "guild_id" => "100",
        "content" => "<@9999> hi",
        "mentions" => [%{"id" => "9999"}]
      }

      assert {:ok, "mention"} = AttentionPolicy.message_attention(message, source())
    end

    test "ignored channel rejects" do
      src = source(%{attention: %{source().attention | "ignored_channel_ids" => ["bad"]}})
      message = %{"channel_id" => "bad", "guild_id" => "100"}
      assert {:ignore, :ignored_channel} = AttentionPolicy.message_attention(message, src)
    end

    test "allowlist takes precedence over free response" do
      src =
        source(%{
          attention: %{
            source().attention
            | "allowed_channel_ids" => ["good"],
              "require_mention" => false
          }
        })

      bad = %{"channel_id" => "bad", "guild_id" => "100"}
      assert {:ignore, :outside_allowlist} = AttentionPolicy.message_attention(bad, src)

      good = %{"channel_id" => "good", "guild_id" => "100"}
      assert {:ok, "free_response"} = AttentionPolicy.message_attention(good, src)
    end

    test "unmentioned guild message is ignored when require_mention" do
      message = %{"channel_id" => "1", "guild_id" => "100", "content" => "hi", "mentions" => []}

      assert {:ignore, :unmentioned_guild_message} =
               AttentionPolicy.message_attention(message, source())
    end

    test "free_response_channel_ids opts a single channel in" do
      src =
        source(%{
          attention: %{
            source().attention
            | "free_response_channel_ids" => ["chatty"]
          }
        })

      chatty = %{"channel_id" => "chatty", "guild_id" => "100", "content" => "anything"}
      assert {:ok, "free_response"} = AttentionPolicy.message_attention(chatty, src)
    end
  end

  describe "interaction_attention/2" do
    test "always accepts application command when not ignored/outside allowlist" do
      interaction = %{"channel_id" => "1", "guild_id" => "100"}

      assert {:ok, "application_command"} =
               AttentionPolicy.interaction_attention(interaction, source())
    end

    test "rejects ignored channel" do
      src = source(%{attention: %{source().attention | "ignored_channel_ids" => ["bad"]}})
      interaction = %{"channel_id" => "bad", "guild_id" => "100"}
      assert {:ignore, :ignored_channel} = AttentionPolicy.interaction_attention(interaction, src)
    end
  end

  describe "mentions_bot?/2" do
    test "uses the mentions list when bot id is known" do
      message = %{"mentions" => [%{"id" => "9999"}, %{"id" => "1"}]}
      assert AttentionPolicy.mentions_bot?(message, source())
    end

    test "returns false when bot id is unknown" do
      src = source(%{bot_user_id: nil})
      message = %{"mentions" => [%{"id" => "9999"}]}
      refute AttentionPolicy.mentions_bot?(message, src)
    end
  end
end
