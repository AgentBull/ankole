defmodule BullxTelegram.DirectCommandTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias BullX.Plugins.{Extension, Registry, Spec}
  alias BullX.Principals
  alias BullX.Principals.{ActivationCode, ExternalIdentity, PrincipalLoginAuthCode}
  alias BullxTelegram.{DirectCommand, Source}

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    previous_registry = :sys.get_state(Registry)
    dispatcher_pid = unregister_dispatcher()

    configure_registry!()
    configure_credentials!()
    configure_source!()

    on_exit(fn ->
      restore_dispatcher(dispatcher_pid)
      :sys.replace_state(Registry, fn _state -> previous_registry end)
      BullX.Config.delete("bullx.gateway.sources")
      BullX.Config.delete("bullx.plugins.telegram.credentials")
    end)

    :ok
  end

  test "/preauth in group chat replies without consuming an activation code" do
    {:ok, %{code: code, activation_code: activation_code}} =
      Principals.create_activation_code(nil, %{"purpose" => "telegram-direct-command-test"})

    assert {:ok, %{"command_name" => "preauth", "status" => "accepted"}} =
             DirectCommand.handle(command("preauth", args: code, chat_type: "group"), source())

    refute Repo.get!(ActivationCode, activation_code.id).used_at
  end

  test "/web_auth in group chat replies without issuing a login auth code" do
    bind_human!("telegram:999")

    assert Repo.aggregate(PrincipalLoginAuthCode, :count) == 0

    assert {:ok, %{"command_name" => "web_auth", "status" => "accepted"}} =
             DirectCommand.handle(command("web_auth", chat_type: "group"), source())

    assert Repo.aggregate(PrincipalLoginAuthCode, :count) == 0
  end

  test "/ping accepts without requiring activation" do
    assert {:ok, %{"command_name" => "ping", "status" => "accepted"}} =
             DirectCommand.handle(command("ping"), source())
  end

  defp configure_registry! do
    extension = %Extension{
      plugin_id: "bullx_telegram",
      point: :"bullx.gateway.adapter",
      id: "telegram",
      module: BullxTelegram.GatewayAdapter
    }

    spec = %Spec{
      app: :bullx_telegram,
      id: "bullx_telegram",
      module: BullxTelegram.Plugin,
      api_version: 1,
      extensions: [extension],
      config_modules: [BullxTelegram.Config]
    }

    {:ok, state} = Registry.build([spec], ["bullx_telegram"])
    :sys.replace_state(Registry, fn _state -> state end)
  end

  defp configure_credentials! do
    payload =
      Jason.encode!(%{
        "default" => %{"bot_token" => "test_token", "bot_username" => "test_bot"}
      })

    BullX.Config.put("bullx.plugins.telegram.credentials", payload)
  end

  defp configure_source! do
    source = %{
      "adapter" => "telegram",
      "channel_id" => "main",
      "enabled" => true,
      "config" => %{},
      "outbound_retry" => %{"max_attempts" => 1}
    }

    {:ok, normalized} = SourceConfig.normalize(source)

    source =
      Map.put(source, "connectivity", %{
        "status" => "ok",
        "fingerprint" => SourceConfig.fingerprint(normalized),
        "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    BullX.Config.put("bullx.gateway.sources", Jason.encode!([source]))
  end

  defp bind_human!(external_id) do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{
        uid: "telegram-direct-command-#{System.unique_integer([:positive])}",
        display_name: "Telegram Direct Command"
      })

    %ExternalIdentity{}
    |> ExternalIdentity.changeset(%{
      principal_id: principal.id,
      kind: :channel_actor,
      adapter: "telegram",
      channel_id: "main",
      external_id: external_id,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp command(name, attrs \\ []) do
    Map.merge(
      %{
        event_id: "evt_#{System.unique_integer([:positive])}",
        name: name,
        args: "",
        chat_type: "private",
        chat_id: "999",
        thread_id: nil,
        message_id: "1",
        actor: %{id: "telegram:999"},
        account_input: %{
          "adapter" => "telegram",
          "channel_id" => "main",
          "external_id" => "telegram:999",
          "profile" => %{"display_name" => "Alice"},
          "metadata" => %{}
        }
      },
      Map.new(attrs)
    )
  end

  defp unregister_dispatcher do
    case Process.whereis(BullX.Gateway.Outbound.Dispatcher) do
      nil ->
        nil

      pid ->
        Process.unregister(BullX.Gateway.Outbound.Dispatcher)
        pid
    end
  end

  defp restore_dispatcher(nil), do: :ok

  defp restore_dispatcher(pid) when is_pid(pid) do
    case Process.whereis(BullX.Gateway.Outbound.Dispatcher) do
      nil ->
        if Process.alive?(pid) do
          Process.register(pid, BullX.Gateway.Outbound.Dispatcher)
        end

      _ ->
        :ok
    end
  end

  defp source do
    %Source{adapter: "telegram", channel_id: "main"}
  end
end
