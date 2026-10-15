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

  setup do
    allow_cache_database_access()
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
    assert {:ok, ^expected} = Bindings.binding_config_in_tx(Repo, binding, Config)
    assert %Config.Runtime{channel_id: "1650000001"} = Config.runtime_config(expected)
  end

  test "missing binding and missing configuration keep separate errors", %{
    binding: binding,
    intent: intent
  } do
    assert :error = Bindings.binding_config(binding, Config)
    assert :error = Bindings.binding_config_in_tx(Repo, binding, Config)
    assert {:error, :binding_config_not_found} = Bindings.delivery_config(intent, Config)

    assert {:error, :binding_not_found} =
             Bindings.delivery_config(%{intent | binding_name: "absent"}, Config)
  end

  test "configuration references use the declared app-config URI", %{binding: binding} do
    for ref <- [nil, "app-config:legacy", "legacy"] do
      invalid = %{binding | config_ref: ref}
      assert {:error, :invalid_config_ref} = Bindings.binding_config(invalid, Config)
      assert {:error, :invalid_config_ref} = Bindings.binding_config_in_tx(Repo, invalid, Config)
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
             Bindings.binding_config_in_tx(Repo, binding, Config)

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
end
