defmodule Ankole.Signals.BindingConfigTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.Plugins.EmailAdapter.Delivery, as: EmailDelivery
  alias Ankole.Plugins.LineAdapter.Config
  alias Ankole.Signals.Bindings
  alias Ankole.Conversations.Delivery.Intent

  defmodule FailingSaveHook do
    def handle_binding_saved(_binding, %{"channelSecret" => "raise"}),
      do: raise("adapter save unavailable")

    def handle_binding_saved(_binding, _config), do: {:error, :adapter_save_unavailable}
  end

  setup do
    %{principal: agent} = agent_fixture()
    binding = binding_fixture(agent.uid, "config-owner", :ignore, adapter: "line")
    key = Config.binding_config_key(agent.uid, binding.name)

    binding =
      binding |> Ecto.Changeset.change(config_ref: "app-config://#{key}") |> Repo.update!()

    %{
      binding: binding,
      key: key,
      intent: %Intent{agent_uid: agent.uid, binding_name: binding.name}
    }
  end

  test "runtime and transaction reads use the same validation", %{binding: binding, key: key} do
    value = %{
      "channelId" => "1650000001",
      "channelSecret" => "secret",
      "channelAccessToken" => "token"
    }

    assert {:ok, expected} = Config.validate_binding_config(value)
    assert {:ok, _} = AppConfigure.put_global_by_key(key, value)
    assert {:ok, ^expected} = Bindings.binding_config(binding, Config)
    assert {:ok, ^expected} = Bindings.binding_config_in_tx(binding, Config)
    assert %Config.Runtime{channel_id: "1650000001"} = Config.runtime_config(expected)
  end

  test "missing binding and missing configuration keep separate errors", %{
    binding: binding,
    intent: intent
  } do
    assert :error = Bindings.binding_config(binding, Config)
    assert :error = Bindings.binding_config_in_tx(binding, Config)
    assert {:error, :binding_config_not_found} = Bindings.delivery_config(intent, Config)

    assert {:error, :binding_not_found} =
             Bindings.delivery_config(%{intent | binding_name: "absent"}, Config)
  end

  test "configuration references use the declared app-config URI", %{binding: binding} do
    for ref <- [nil, "app-config:legacy", "legacy"] do
      invalid = %{binding | config_ref: ref}
      assert {:error, :invalid_config_ref} = Bindings.binding_config(invalid, Config)
      assert {:error, :invalid_config_ref} = Bindings.binding_config_in_tx(invalid, Config)
    end
  end

  test "invalid stored configuration remains an error", %{
    binding: binding,
    key: key,
    intent: intent
  } do
    # A damaged encrypted row is distinct from an absent configuration row.
    assert {:ok, ciphertext} = Crypto.seal(%{"channelId" => "invalid"}, "global", key)

    Repo.insert!(%SiteConfig{
      scope: "global",
      key: key,
      value: %{"type" => "cipher", "value" => ciphertext}
    })

    assert {:error, {:storage_error, "global", ^key, _}} =
             Bindings.binding_config(binding, Config)

    assert {:error, {:storage_error, "global", ^key, _}} =
             Bindings.binding_config_in_tx(binding, Config)

    assert {:error, {:storage_error, "global", ^key, _}} =
             Bindings.delivery_config(intent, Config)
  end

  test "Email missing configuration needs operator action", %{binding: binding, intent: intent} do
    email_key =
      Ankole.Plugins.EmailAdapter.Config.binding_config_key(binding.agent_uid, binding.name)

    binding
    |> Ecto.Changeset.change(adapter: "email", config_ref: "app-config://#{email_key}")
    |> Repo.update!()

    assert {:error,
            {:reply_delivery, :operator_action_required, %{"code" => "binding_config_not_found"}}} =
             EmailDelivery.deliver(intent)
  end

  @tag :unit
  test "a failed adapter hook preserves the save and wakes blocked delivery", %{binding: binding} do
    original = Ankole.Plugins.Registry.snapshot_for_test()
    spec = original.active["line-adapter"]

    spec = %{
      spec
      | adapter_declarations:
          Enum.map(spec.adapter_declarations, fn
            %{contract_id: "signals.adapter"} = declaration ->
              Map.put(declaration, :binding_saved_module, FailingSaveHook)

            declaration ->
              declaration
          end)
    }

    Ankole.Plugins.Registry.update_for_test(fn state ->
      %{
        state
        | active: Map.put(state.active, spec.id, spec),
          discovered: Map.put(state.discovered, spec.id, spec)
      }
    end)

    on_exit(fn -> Ankole.Plugins.Registry.update_for_test(fn _ -> original end) end)

    config = %{
      "channelId" => "1650000001",
      "channelSecret" => "secret",
      "channelAccessToken" => "token"
    }

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        assert {:ok, %{binding: saved}} =
                 Bindings.put_binding(binding.agent_uid, "line", binding.name, %{
                   "config" => config
                 })

        assert {:ok, ^config} = Bindings.stored_binding_config(saved)

        conversation =
          Ankole.ExternalConversationsFixtures.external_conversation_fixture("line:hook-test")

        assert {:ok, intent} =
                 commit_delivery(%{
                   agent_uid: saved.agent_uid,
                   binding_name: saved.name,
                   outbound_key: "blocked-hook",
                   delivery_class: :durable_ai_reply,
                   operation: :post,
                   conversation_id: conversation.id,
                   fallback_visible_text: "Reply"
                 })

        assert {:ok, blocked} =
                 Repo.transact(fn ->
                   Ankole.Conversations.Delivery.Recovery.mark_intent_failed(
                     intent,
                     {:reply_delivery, :operator_action_required,
                      %{"code" => "credentials_expired"}},
                     DateTime.utc_now(:microsecond)
                   )
                 end)

        assert blocked.recovery_status == :blocked
        assert is_nil(blocked.next_attempt_at)

        assert {:ok, %{binding: updated}} =
                 Bindings.update_binding(saved.agent_uid, saved.agent_uid, saved.name, %{
                   "config" => %{"channelSecret" => "raise"}
                 })

        assert {:ok, %{"channelSecret" => "raise"}} = Bindings.stored_binding_config(updated)

        woken =
          Repo.get_by!(Intent,
            agent_uid: intent.agent_uid,
            binding_name: intent.binding_name,
            outbound_key: intent.outbound_key
          )

        assert %DateTime{} = woken.next_attempt_at
        assert is_nil(woken.recovery_status)
      end)

    assert log =~ "signals.binding_publication_failed"
    assert log =~ "adapter_save_unavailable"
    assert log =~ "Elixir.RuntimeError"
    assert log =~ "FailingSaveHook.handle_binding_saved/2"
  end
end
