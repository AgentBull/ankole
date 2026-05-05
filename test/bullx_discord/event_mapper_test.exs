defmodule BullXDiscord.EventMapperTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Delivery.Content
  alias BullXGateway.Inputs.{Message, SlashCommand}
  alias BullXDiscord.{Cache, Config, EventMapper, ThreadOwnership}

  test "maps bot-mentioned guild messages and strips the mention from content" do
    config = config()

    message = %{
      id: "message-1",
      channel_id: "channel-1",
      guild_id: "guild-1",
      content: "<@bot-1> summarize this",
      author: %{id: "user-1", username: "alice", global_name: "Alice", bot: false},
      mentions: [%{id: "bot-1"}]
    }

    assert {:ok, %{input: %Message{} = input, account_input: account_input, auto_thread?: true},
            _cache} = EventMapper.map_message(message, config, Cache.new())

    assert input.id == "message-1"
    assert input.channel == {:discord, "default"}
    assert input.scope_id == "channel-1"
    assert input.thread_id == nil
    assert input.actor == %{id: "discord:user-1", display: "Alice", bot: false}

    assert input.reply_channel == %{
             adapter: :discord,
             channel_id: "default",
             scope_id: "channel-1",
             thread_id: nil
           }

    assert [%Content{kind: :text, body: %{"text" => "summarize this"}}] = input.content
    assert input.event.data["discord"]["attention_reason"] == "mention"
    assert account_input.external_id == "discord:user-1"
    assert account_input.profile["display_name"] == "Alice"
  end

  test "maps /ask interactions to SlashCommand inputs" do
    config = config()

    interaction = %{
      id: "interaction-1",
      channel_id: "channel-1",
      guild_id: "guild-1",
      user: %{id: "user-1", username: "alice"},
      data: %{
        name: "ask",
        options: [%{name: "prompt", value: "what changed?"}]
      }
    }

    assert {:ok, %{input: %SlashCommand{} = input, interaction: ^interaction, auto_thread?: true},
            _cache} = EventMapper.map_interaction(interaction, config, Cache.new())

    assert input.id == "interaction-1"
    assert input.command_name == "ask"
    assert input.args == "what changed?"
    assert input.scope_id == "channel-1"
    assert input.event.data["discord"]["attention_reason"] == "application_command"
    assert [%Content{body: %{"text" => "what changed?"}}] = input.content
  end

  test "strips bot mentions from owned-thread messages before publishing" do
    config = config()
    cache = Cache.new() |> ThreadOwnership.mark_owned(config, "thread-1")

    message = %{
      id: "message-1",
      channel_id: "thread-1",
      guild_id: "guild-1",
      content: "<@bot-1> continue here",
      author: %{id: "user-1", username: "alice", bot: false},
      mentions: []
    }

    assert {:ok, %{input: %Message{} = input}, _cache} =
             EventMapper.map_message(message, config, cache)

    assert input.event.data["discord"]["attention_reason"] == "owned_thread"
    assert [%Content{kind: :text, body: %{"text" => "continue here"}}] = input.content
  end

  test "maps adapter-local commands without publishing them as Gateway inputs" do
    config = config()

    message = %{
      id: "message-1",
      channel_id: "dm-1",
      guild_id: nil,
      content: "/preauth ABC123",
      author: %{id: "user-1", username: "alice", bot: false}
    }

    assert {:direct_command,
            %{
              name: "preauth",
              args: "ABC123",
              transport: :message,
              dm?: true,
              account_input: %{external_id: "discord:user-1"}
            }, _cache} = EventMapper.map_message(message, config, Cache.new())
  end

  test "rejects empty message content after mention stripping" do
    config = config()

    message = %{
      id: "message-1",
      channel_id: "channel-1",
      guild_id: "guild-1",
      content: "<@bot-1>",
      author: %{id: "user-1", username: "alice", bot: false},
      mentions: [%{id: "bot-1"}]
    }

    assert {:error, %{"kind" => "payload"}, _cache} =
             EventMapper.map_message(message, config, Cache.new())
  end

  defp config do
    {:ok, config} =
      Config.normalize({:discord, "default"}, %{
        application_id: "app",
        bot_token: "bot",
        client_secret: "secret",
        bot_user_id: "bot-1"
      })

    config
  end
end
