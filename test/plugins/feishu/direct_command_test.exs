defmodule Feishu.DirectCommandTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias BullX.Plugins.{Extension, Registry, Spec}
  alias BullX.Principals
  alias BullX.Principals.{ActivationCode, ExternalIdentity, PrincipalLoginAuthCode}
  alias Feishu.DirectCommand

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    previous_registry = :sys.get_state(Registry)
    dispatcher_pid = unregister_dispatcher()

    configure_registry!()
    configure_source!()

    on_exit(fn ->
      restore_dispatcher(dispatcher_pid)
      :sys.replace_state(Registry, fn _state -> previous_registry end)
      BullX.Config.delete("bullx.gateway.sources")
    end)

    :ok
  end

  test "/preauth in group chat replies without consuming an activation code" do
    {:ok, %{code: code, activation_code: activation_code}} =
      Principals.create_activation_code(nil, %{"purpose" => "feishu-direct-command-test"})

    assert {:ok, %{"command_name" => "preauth", "status" => "accepted"}} =
             DirectCommand.handle(command("preauth", args: code, chat_type: "group"), source())

    refute Repo.get!(ActivationCode, activation_code.id).used_at
  end

  test "/web_auth in group chat replies without issuing a login auth code" do
    bind_human!("feishu:ou_user")

    assert Repo.aggregate(PrincipalLoginAuthCode, :count) == 0

    assert {:ok, %{"command_name" => "web_auth", "status" => "accepted"}} =
             DirectCommand.handle(command("web_auth", chat_type: "group"), source())

    assert Repo.aggregate(PrincipalLoginAuthCode, :count) == 0
  end

  defp configure_registry! do
    extension = %Extension{
      plugin_id: "feishu",
      point: :"bullx.gateway.adapter",
      id: "feishu",
      module: Feishu.GatewayAdapter
    }

    spec = %Spec{
      app: :feishu,
      id: "feishu",
      module: Feishu.Plugin,
      api_version: 1,
      extensions: [extension],
      config_modules: [Feishu.Config]
    }

    {:ok, state} = Registry.build([spec], ["feishu"])
    :sys.replace_state(Registry, fn _state -> state end)
  end

  defp configure_source! do
    source = %{
      "adapter" => "feishu",
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
        uid: "feishu-direct-command-#{System.unique_integer([:positive])}",
        display_name: "Feishu Direct Command"
      })

    %ExternalIdentity{}
    |> ExternalIdentity.changeset(%{
      principal_id: principal.id,
      kind: :channel_actor,
      adapter: "feishu",
      channel_id: "main",
      external_id: external_id,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp command(name, attrs) do
    Map.merge(
      %{
        event_id: "evt_#{System.unique_integer([:positive])}",
        name: name,
        args: "",
        chat_type: "p2p",
        chat_id: "oc_1",
        thread_id: nil,
        message_id: "om_1",
        actor: %{id: "feishu:ou_user"},
        account_input: %{
          adapter: "feishu",
          channel_id: "main",
          external_id: "feishu:ou_user",
          profile: %{"display_name" => "Alice"},
          metadata: %{}
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
    %Feishu.Source{adapter: "feishu", channel_id: "main"}
  end
end
