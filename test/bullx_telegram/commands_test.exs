defmodule BullXTelegram.CommandsTest do
  use ExUnit.Case, async: false

  alias BullXTelegram.{Commands, Config}

  defmodule ApiStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def request(token, method, params) do
      send(:persistent_term.get(@pid_key), {:request, token, method, params})
      {:ok, %{"ok" => true}}
    end
  end

  setup do
    ApiStub.put_pid(self())
    on_exit(&ApiStub.clear/0)
    :ok
  end

  test "registers the full Telegram command menu with replace policy" do
    assert {:ok, _result} = Commands.sync(config(%{commands: %{sync_policy: "replace"}}))

    assert_receive {:request, "bot", "setMyCommands", params}
    assert {:json, commands} = params[:commands]
    assert Enum.map(commands, & &1.command) == ["ping", "preauth", "web_auth", "ask"]
  end

  test "does not modify Telegram command menu when sync is off" do
    assert {:ok, :off} = Commands.sync(config(%{commands: %{sync_policy: "off"}}))

    refute_receive {:request, _, _, _}
  end

  defp config(attrs) do
    {:ok, config} =
      Config.normalize(
        {:telegram, "default"},
        Map.merge(%{bot_token: "bot", api_module: ApiStub}, attrs)
      )

    config
  end
end
