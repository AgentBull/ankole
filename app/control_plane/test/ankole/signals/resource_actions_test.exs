defmodule Ankole.Signals.ResourceActionsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.Signals.{Binding, Webhooks}

  test "Binding replacement keeps its identity and creation time and resets omitted configuration" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      agent_uid: agent.uid,
      name: "resource-binding",
      adapter: "mock",
      config_ref: "app-config://first",
      filters: %{"cel" => "true"},
      target: %{"session_id" => "configured-session"},
      unaddressed_group_message_policy: :may_intervene,
      unmatched_sender_policy: :create_standalone,
      enabled: false,
      unavailable_reason: "old credentials"
    }

    assert {:ok, original} = Ankole.SignalsFixtures.raw_binding_fixture(attrs)

    replacement =
      attrs
      |> Map.take([:agent_uid, :name, :adapter])
      |> Map.put(:config_ref, "app-config://second")

    assert {:ok, binding} = Ankole.SignalsFixtures.raw_binding_fixture(replacement)
    assert binding.agent_uid == original.agent_uid
    assert binding.name == original.name
    assert binding.inserted_at == original.inserted_at
    assert binding.config_ref == "app-config://second"
    assert binding.filters == %{}
    assert binding.target == %{}
    assert binding.unaddressed_group_message_policy == :record_only
    assert binding.unmatched_sender_policy == :manual_review
    assert binding.enabled
    assert binding.unavailable_reason == nil

    Ankole.DataCase.assert_persisted_equal(
      Repo.get_by!(Binding, agent_uid: agent.uid, name: binding.name),
      binding
    )

    assert {:ok, disabled} =
             Repo.transact(fn _ -> Ankole.Ash.update(binding, :disable, %{}) end)

    refute disabled.enabled
    assert disabled.config_ref == binding.config_ref

    assert {:ok, _removed} =
             Repo.transact(fn _ -> Ankole.Ash.destroy(disabled, :remove) end)

    refute Repo.get_by(Binding, agent_uid: agent.uid, name: binding.name)
  end

  test "Webhook actions require terminal evidence and cannot revive a consumed capability" do
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(%{
               event_format: "cloudevents",
               label: "Resource transition",
               mode: "one_shot",
               expires_at: DateTime.add(now, 3600)
             })

    assert endpoint.status == :armed

    assert {:error, %Ash.Error.Invalid{} = error} =
             Repo.transact(fn _ -> Ankole.Ash.update(endpoint, :fire, %{}) end)

    assert [%{path: "fired_at", message: "must be present"}] =
             Ankole.Ash.validation_details(error)

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(endpoint), endpoint)

    assert {:ok, fired} =
             Repo.transact(fn _ -> Ankole.Ash.update(endpoint, :fire, %{fired_at: now}) end)

    assert fired.status == :fired
    assert fired.fired_at == now
    assert fired.cancelled_at == nil

    assert {:error, %Ash.Error.Invalid{}} =
             Repo.transact(fn _ -> Ankole.Ash.update(fired, :cancel, %{cancelled_at: now}) end)

    assert Webhooks.expire_due(DateTime.add(now, 7200)) == 0
    Ankole.DataCase.assert_persisted_equal(Repo.reload!(fired), fired)
  end
end
