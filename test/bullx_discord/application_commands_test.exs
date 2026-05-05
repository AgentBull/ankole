defmodule BullXDiscord.ApplicationCommandsTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.{ApplicationCommands, Config}

  defmodule CommandAPI do
    @pid_key {__MODULE__, :pid}
    @commands_key {__MODULE__, :commands}

    def put(pid, commands) do
      :persistent_term.put(@pid_key, pid)
      :persistent_term.put(@commands_key, commands)
    end

    def clear do
      :persistent_term.erase(@pid_key)
      :persistent_term.erase(@commands_key)
    end

    def global_commands(application_id) do
      send(:persistent_term.get(@pid_key), {:global_commands, application_id})
      {:ok, :persistent_term.get(@commands_key)}
    end

    def create_global_command(application_id, payload) do
      send(:persistent_term.get(@pid_key), {:create, application_id, payload})
      {:ok, Map.put(payload, :id, "created-#{payload.name}")}
    end

    def edit_global_command(application_id, command_id, payload) do
      send(:persistent_term.get(@pid_key), {:edit, application_id, command_id, payload})
      {:ok, Map.put(payload, :id, command_id)}
    end

    def delete_global_command(application_id, command_id) do
      send(:persistent_term.get(@pid_key), {:delete, application_id, command_id})
      :ok
    end
  end

  setup do
    on_exit(&CommandAPI.clear/0)
    :ok
  end

  test "skips command sync when policy is off" do
    config = config(%{application_commands: %{sync_policy: "off"}})

    assert {:ok, %{status: "skipped", reason: "disabled"}} = ApplicationCommands.sync(config)
  end

  test "safely reconciles only BullX-owned global commands" do
    CommandAPI.put(self(), [
      %{id: "ping-1", name: "ping", description: "old", type: 1},
      %{id: "other-1", name: "third_party", description: "keep", type: 1}
    ])

    assert {:ok, %{status: "synced"} = result} = ApplicationCommands.sync(config())

    assert_receive {:global_commands, 123}
    assert_receive {:edit, 123, "ping-1", %{name: "ping"}}

    created =
      collect_messages(:create)
      |> Enum.map(fn {:create, 123, %{name: name}} -> name end)
      |> Enum.sort()

    assert created == ["ask", "preauth", "web_auth"]
    assert Enum.sort(result.created) == created
    assert result.edited == ["ping"]
    assert result.deleted == []
    refute_receive {:delete, 123, "other-1"}
  end

  defp collect_messages(tag, acc \\ []) do
    receive do
      {^tag, _, _} = message -> collect_messages(tag, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp config(attrs \\ %{}) do
    base = %{
      application_id: "123",
      bot_token: "bot",
      client_secret: "secret",
      application_command_api: CommandAPI
    }

    {:ok, config} = Config.normalize({:discord, "default"}, Map.merge(base, attrs))
    config
  end
end
