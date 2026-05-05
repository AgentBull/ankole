defmodule BullXDiscord.ConsumerTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.{Cache, Config, Consumer}

  defmodule GatewayStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def publish_inbound(input) do
      send(:persistent_term.get(@pid_key), {:publish, input})
      {:ok, %{published: input.id}}
    end

    def deliver(delivery) do
      send(:persistent_term.get(@pid_key), {:delivery, delivery})
      {:ok, delivery.id}
    end
  end

  defmodule AccountsBound do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def match_or_create_from_channel(input) do
      send(:persistent_term.get(@pid_key), {:account_gate, input})
      {:ok, %{id: "user-1"}, %{id: "binding-1"}}
    end

    def consume_activation_code(_code, _input), do: raise("direct command not expected")

    def issue_user_channel_auth_code(_adapter, _channel_id, _external_id),
      do: raise("not expected")
  end

  defmodule AccountsActivationRequired do
    def match_or_create_from_channel(_input), do: {:error, :activation_required}
    def consume_activation_code(_code, _input), do: raise("direct command not expected")

    def issue_user_channel_auth_code(_adapter, _channel_id, _external_id),
      do: raise("not expected")
  end

  defmodule ChannelAPI do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def get(channel_id) do
      send(:persistent_term.get(@pid_key), {:get_channel, channel_id})
      {:ok, %{id: channel_id, type: 0}}
    end
  end

  defmodule ThreadAPI do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def create_with_message(channel_id, message_id, options) do
      send(
        :persistent_term.get(@pid_key),
        {:create_thread_with_message, channel_id, message_id, options}
      )

      {:ok, %{id: "thread-1"}}
    end

    def create(channel_id, options) do
      send(:persistent_term.get(@pid_key), {:create_thread, channel_id, options})
      {:ok, %{id: "thread-1"}}
    end
  end

  defmodule InteractionAPI do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def create_response(interaction, response) do
      send(:persistent_term.get(@pid_key), {:interaction_response, interaction, response})
      :ok
    end
  end

  setup do
    for module <- [GatewayStub, AccountsBound, ChannelAPI, ThreadAPI, InteractionAPI] do
      module.put_pid(self())
    end

    on_exit(fn ->
      for module <- [GatewayStub, AccountsBound, ChannelAPI, ThreadAPI, InteractionAPI] do
        module.clear()
      end
    end)

    :ok
  end

  test "runs account gate, creates a BullX-owned thread, then publishes mapped input" do
    state = state(accounts_module: AccountsBound)

    assert {{:ok, %{published: "654"}}, state} =
             Consumer.handle_event({:MESSAGE_CREATE, mention_message(), nil}, state)

    assert_receive {:account_gate, %{external_id: "discord:user-1"}}
    assert_receive {:get_channel, 321}

    assert_receive {:create_thread_with_message, 321, 654,
                    %{name: "please help", auto_archive_duration: 60}}

    assert_receive {:publish, input}

    assert input.scope_id == "thread-1"
    assert input.reply_channel.scope_id == "thread-1"
    assert state.cache != nil
  end

  test "activation-required guild actors do not reach Runtime and get local guidance" do
    state = state(accounts_module: AccountsActivationRequired)

    assert {{:ok, %{command_name: "activation_required"}}, _state} =
             Consumer.handle_event({:MESSAGE_CREATE, mention_message(), nil}, state)

    refute_receive {:publish, _input}
    refute_receive {:create_thread_with_message, _, _, _}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "DM the bot"
  end

  test "activation-required /ask receives an ephemeral interaction response" do
    state = state(accounts_module: AccountsActivationRequired)

    assert {{:ok,
             %{
               interaction_id: "interaction-1:activation_required",
               command_name: "activation_required"
             }}, _state} =
             Consumer.handle_event({:INTERACTION_CREATE, ask_interaction(), nil}, state)

    refute_receive {:publish, _input}
    refute_receive {:create_thread, _, _}

    assert_receive {:interaction_response, %{id: "interaction-1"},
                    %{type: 4, data: %{flags: 64, content: content}}}

    assert content =~ "DM the bot"
  end

  defp state(config_attrs) do
    %{config: config(config_attrs), cache: Cache.new()}
  end

  defp config(attrs) do
    base = %{
      application_id: "app",
      bot_token: "bot",
      client_secret: "secret",
      bot_user_id: "bot-1",
      gateway_module: GatewayStub,
      channel_api: ChannelAPI,
      thread_api: ThreadAPI,
      interaction_api: InteractionAPI,
      auto_thread: %{auto_archive_duration_minutes: 60}
    }

    {:ok, config} = Config.normalize({:discord, "default"}, Map.merge(base, Map.new(attrs)))
    config
  end

  defp mention_message do
    %{
      id: "654",
      channel_id: "321",
      guild_id: "987",
      content: "<@bot-1> please help",
      author: %{id: "user-1", username: "alice", bot: false},
      mentions: [%{id: "bot-1"}]
    }
  end

  defp ask_interaction do
    %{
      id: "interaction-1",
      channel_id: "321",
      guild_id: "987",
      user: %{id: "user-1", username: "alice"},
      data: %{name: "ask", options: [%{name: "prompt", value: "please help"}]}
    }
  end
end
