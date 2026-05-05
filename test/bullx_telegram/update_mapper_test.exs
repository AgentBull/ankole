defmodule BullXTelegram.UpdateMapperTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Delivery.Content
  alias BullXGateway.Inputs.{Message, SlashCommand}
  alias BullXTelegram.{Cache, Config, UpdateMapper}

  test "maps private Telegram text messages to Gateway Message inputs" do
    config = config()

    update = update(%{"text" => "hello"})

    assert {:ok, %{input: %Message{} = input, account_input: account_input}, _cache} =
             UpdateMapper.map_update(update, config, Cache.new())

    assert input.id == "100:10"
    assert input.channel == {:telegram, "default"}
    assert input.scope_id == "200"
    assert input.thread_id == nil
    assert input.actor == %{id: "telegram:300", display: "Alice", bot: false}

    assert input.reply_channel == %{
             adapter: :telegram,
             channel_id: "default",
             scope_id: "200",
             thread_id: nil
           }

    assert [%Content{kind: :text, body: %{"text" => "hello"}}] = input.content
    assert input.event.data["telegram"]["attention_reason"] == "dm"
    assert account_input.external_id == "telegram:300"
  end

  test "maps /ask commands to SlashCommand inputs with prompt content" do
    config = config()
    update = update(%{"text" => "/ask@BullXBot what changed?", "message_thread_id" => 77})

    assert {:ok, %{input: %SlashCommand{} = input}, _cache} =
             UpdateMapper.map_update(update, config, Cache.new())

    assert input.id == "100:10:ask"
    assert input.command_name == "ask"
    assert input.args == "what changed?"
    assert input.thread_id == "77"
    assert [%Content{body: %{"text" => "what changed?"}}] = input.content
  end

  test "maps adapter-local commands without publishing them as Gateway inputs" do
    config = config()
    update = update(%{"text" => "/preauth ACT123"})

    assert {:direct_command,
            %{
              name: "preauth",
              args: "ACT123",
              chat_type: "private",
              account_input: %{external_id: "telegram:300"}
            }, _cache} = UpdateMapper.map_update(update, config, Cache.new())
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

  defp update(attrs) do
    %{
      "update_id" => 100,
      "message" =>
        Map.merge(
          %{
            "message_id" => 10,
            "date" => 1_777_777_777,
            "chat" => %{"id" => 200, "type" => "private"},
            "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false}
          },
          attrs
        )
    }
  end
end
