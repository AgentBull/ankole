defmodule BullXDiscord.AttentionPolicyTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.{AttentionPolicy, Cache, Config}

  defmodule ChannelAPI do
    @channel_key {__MODULE__, :channel}
    @pid_key {__MODULE__, :pid}

    def put_channel(channel), do: :persistent_term.put(@channel_key, channel)
    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)

    def clear,
      do:
        (
          :persistent_term.erase(@channel_key)
          :persistent_term.erase(@pid_key)
        )

    def get(channel_id) do
      send(:persistent_term.get(@pid_key), {:get_channel, channel_id})
      {:ok, :persistent_term.get(@channel_key)}
    end
  end

  setup do
    ChannelAPI.put_pid(self())
    ChannelAPI.put_channel(%{id: "thread-1", type: 11, owner_id: "bot-1"})
    on_exit(&ChannelAPI.clear/0)

    {:ok, config: config(), cache: Cache.new()}
  end

  test "accepts DMs without a bot mention", %{config: config, cache: cache} do
    message = message(%{guild_id: nil, channel_id: "dm-1", content: "hello"})

    assert {:ok, "dm", ^cache} = AttentionPolicy.message_attention(message, config, cache)
  end

  test "accepts guild messages that mention the bot", %{config: config, cache: cache} do
    message =
      message(%{
        guild_id: "guild-1",
        channel_id: "channel-1",
        content: "<@bot-1> hello",
        mentions: [%{id: "bot-1"}]
      })

    assert {:ok, "mention", ^cache} = AttentionPolicy.message_attention(message, config, cache)
  end

  test "ignores ordinary unmentioned guild messages", %{config: config, cache: cache} do
    ChannelAPI.put_channel(%{id: "channel-1", type: 0})
    message = message(%{guild_id: "guild-1", channel_id: "channel-1", content: "hello"})

    assert {:ignore, :unmentioned_guild_message, _cache} =
             AttentionPolicy.message_attention(message, config, cache)
  end

  test "accepts follow-up messages inside BullX-owned threads", %{config: config, cache: cache} do
    message = message(%{guild_id: "guild-1", channel_id: "thread-1", content: "follow up"})

    assert {:ok, "owned_thread", cache} =
             AttentionPolicy.message_attention(message, config, cache)

    assert_receive {:get_channel, "thread-1"}

    assert {:ok, "owned_thread", _cache} =
             AttentionPolicy.message_attention(message, config, cache)

    refute_receive {:get_channel, _}
  end

  test "applies ignored and allowed channel filters before attention", %{cache: cache} do
    ignored_config = config(%{attention: %{ignored_channel_ids: ["channel-1"]}})
    allowed_config = config(%{attention: %{allowed_channel_ids: ["channel-2"]}})
    message = message(%{guild_id: "guild-1", channel_id: "channel-1", content: "<@bot-1>"})

    assert {:ignore, :ignored_channel, ^cache} =
             AttentionPolicy.message_attention(message, ignored_config, cache)

    assert {:ignore, :outside_allowlist, ^cache} =
             AttentionPolicy.message_attention(message, allowed_config, cache)
  end

  defp config(attrs \\ %{}) do
    base = %{
      application_id: "app",
      bot_token: "bot",
      client_secret: "secret",
      bot_user_id: "bot-1",
      channel_api: ChannelAPI,
      thread_ownership_cache_ttl_ms: 60_000
    }

    {:ok, config} = Config.normalize({:discord, "default"}, Map.merge(base, attrs))
    config
  end

  defp message(attrs) do
    Map.merge(
      %{
        id: "message-1",
        channel_id: "300",
        guild_id: "guild-1",
        content: "",
        author: %{id: "user-1", username: "alice", bot: false},
        mentions: []
      },
      attrs
    )
  end
end
