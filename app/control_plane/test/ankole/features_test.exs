defmodule Ankole.FeaturesTest.QuotaPlugin do
  @behaviour Ankole.Plugins.Plugin
  @behaviour Ankole.Plugins.Hook

  @impl true
  def plugin_id, do: "fixture-quota"
  @impl true
  def activation, do: :always
  @impl true
  def hooks,
    do: [
      create_agent: __MODULE__,
      create_invitation: __MODULE__,
      enable_signal_binding: __MODULE__
    ]

  @impl true
  def before_commit_in_tx(point, payload) do
    send(self(), {:fixture_hook, point, Ankole.Repo.tenant_id(), Ankole.Repo.in_transaction?()})
    send(self(), {:fixture_hook_payload, point, payload})

    if Process.get(:fixture_write_hook, false) do
      {:ok, _} =
        Ankole.AppConfigure.put_global_by_key_in_tx("features.fixture.experiment", %{
          "enabled" => true,
          "percent" => 100,
          "targets" => %{}
        })
    end

    limit = Map.get(Process.get(:fixture_quotas, %{}), Ankole.Repo.tenant_id())
    binding_limit = Process.get(:fixture_binding_limit)

    cond do
      point in Process.get(:fixture_denied_hooks, []) ->
        {:error, :fixture_denied}

      point == :create_agent and limit != nil and length(Ankole.Principals.list_agents()) >= limit ->
        {:error, :fixture_quota_exceeded}

      point == :enable_signal_binding and binding_limit != nil ->
        {:ok, bindings} = Ankole.Signals.list_bindings()

        if Enum.count(bindings, & &1.enabled) >= binding_limit,
          do: {:error, :fixture_binding_quota_exceeded},
          else: :ok

      true ->
        :ok
    end
  end
end

defmodule Ankole.FeaturesTest.OptionalQuotaPlugin do
  @behaviour Ankole.Plugins.Plugin
  @impl true
  def plugin_id, do: "fixture-optional-quota"
  @impl true
  def hooks, do: [create_agent: Ankole.FeaturesTest.QuotaPlugin]
end

defmodule Ankole.FeaturesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AppConfigure, Features, Repo}
  alias Ankole.Plugins.{Registry, Spec}

  setup do
    flags = Application.get_env(:ankole, :feature_flags)
    snapshot = Registry.snapshot_for_test()
    {:ok, quota} = Spec.from_module(Ankole.FeaturesTest.QuotaPlugin)

    Registry.update_for_test(fn state ->
      %{
        state
        | discovered: Map.put(state.discovered, quota.id, quota),
          active: Map.put(state.active, quota.id, quota)
      }
    end)

    Application.put_env(:ankole, :feature_flags, [
      {"fixture.experiment", [client_visible: true]},
      {"fixture.server", [default: true]}
    ])

    AppConfigure.Registry.clear_for_test()
    AppConfigure.Cache.clear_for_test()

    on_exit(fn ->
      Registry.update_for_test(fn _ -> snapshot end)

      if flags == nil,
        do: Application.delete_env(:ankole, :feature_flags),
        else: Application.put_env(:ankole, :feature_flags, flags)

      AppConfigure.Registry.clear_for_test()
      AppConfigure.Cache.clear_for_test()
    end)

    :ok
  end

  test "OpenFeature rejects unknown keys, supports a site context and exposes only public flags" do
    assert_raise ArgumentError, ~r/undeclared feature/, fn ->
      Features.boolean_value("fixture.typo")
    end

    assert Repo.without_tenant(fn -> Features.boolean_value("fixture.server") end)
    assert Features.client_snapshot() == %{"fixture.experiment" => false}
  end

  test "AppConfigure rejects duplicate feature declarations at startup" do
    Application.put_env(:ankole, :feature_flags, [
      {"fixture.duplicate", []},
      {"fixture.duplicate", [default: true]}
    ])

    assert {:stop, {:duplicate_key, "features.fixture.duplicate"}} =
             AppConfigure.Registry.init([])
  end

  test "the official SDK evaluates flags without wrapper-only context", %{tenant: tenant} do
    client = OpenFeature.get_client()

    assert %OpenFeature.EvaluationDetails{
             key: "fixture.server",
             value: true,
             error_code: nil
           } = OpenFeature.Client.get_boolean_details(client, "fixture.server", false)

    policy(%{"enabled" => true, "percent" => 0, "targets" => %{tenant.id => true}})

    assert OpenFeature.Client.get_boolean_value(client, "fixture.experiment", false,
             context: %{targeting_key: tenant.id}
           )

    refute OpenFeature.Client.get_boolean_value(client, "fixture.experiment", true,
             context: %{targeting_key: "another-consumer"}
           )

    assert Repo.without_tenant(fn ->
             OpenFeature.Client.get_boolean_value(client, "fixture.server", false)
           end)

    original = OpenFeature.get_global_context()
    on_exit(fn -> OpenFeature.set_global_context(original) end)
    OpenFeature.set_global_context(%{targeting_key: "site"})
    refute OpenFeature.Client.get_boolean_value(client, "fixture.experiment", true)
    assert Features.boolean_value("fixture.experiment")
  end

  test "OpenFeature uses declared targets and preserves selected targets when a rollout grows", %{
    tenant: tenant
  } do
    policy(%{"enabled" => true, "percent" => 0, "targets" => %{tenant.id => true}})

    assert %OpenFeature.EvaluationDetails{
             key: "fixture.experiment",
             value: true,
             reason: :targeting_match,
             variant: "true"
           } =
             Features.evaluate_details("fixture.experiment")

    policy(%{"enabled" => false, "percent" => 100, "targets" => %{tenant.id => true}})
    refute Features.boolean_value("fixture.experiment")

    targets = Enum.map(1..60, fn _ -> Ash.UUIDv7.generate() end)

    Enum.reduce([0, 10, 40, 100], MapSet.new(), fn percent, previous ->
      policy(%{"enabled" => true, "percent" => percent, "targets" => %{}})

      selected =
        targets
        |> Enum.filter(&Features.boolean_value("fixture.experiment", %{targeting_key: &1}))
        |> MapSet.new()

      assert MapSet.subset?(previous, selected)
      if percent == 0, do: assert(MapSet.size(selected) == 0)
      if percent == 100, do: assert(MapSet.size(selected) == length(targets))
      selected
    end)

    assert {:error, _} =
             AppConfigure.put_tenant_by_key("features.fixture.experiment", %{
               "enabled" => true,
               "percent" => 100,
               "targets" => %{}
             })
  end

  test "transaction evaluation reads PostgreSQL and a rollback leaves the public snapshot unchanged" do
    assert {:ok, true} =
             Repo.transact(fn -> {:ok, Features.boolean_value_in_tx("fixture.server")} end)

    refute Features.boolean_value("fixture.experiment")

    assert {:error, :fixture_rollback} =
             Repo.transact(fn ->
               {:ok, _} =
                 AppConfigure.put_global_by_key_in_tx("features.fixture.experiment", %{
                   "enabled" => true,
                   "percent" => 100,
                   "targets" => %{}
                 })

               refute Features.boolean_value("fixture.experiment")
               assert Features.boolean_value_in_tx("fixture.experiment")
               {:error, :fixture_rollback}
             end)

    AppConfigure.Cache.clear_for_test()
    refute Features.boolean_value("fixture.experiment")
  end

  test "a site Plugin owns its quota rules while the domain commits the real Agent transaction",
       %{tenant: tenant} do
    %{principal: owner} = human_fixture()
    provider = worker_provider_fixture()
    Process.put(:fixture_quotas, %{tenant.id => 1})

    attrs = %{
      display_name: "Fixture Agent",
      role: "Researcher",
      handle: "first",
      owner_principal_uid: owner.uid,
      worker_provider_id: provider.provider_id
    }

    assert {:ok, _} = Ankole.Principals.create_agent(attrs)
    assert_received {:fixture_hook, :create_agent, tenant_id, true}
    assert tenant_id == tenant.id

    Process.put(:fixture_write_hook, true)

    assert {:error, :fixture_quota_exceeded} =
             Ankole.Principals.create_agent(%{attrs | handle: "over-limit"})

    assert length(Ankole.Principals.list_agents()) == 1
    AppConfigure.Cache.clear_for_test()
    refute Features.boolean_value("fixture.experiment")
    Process.delete(:fixture_write_hook)

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: owner} = human_fixture()
      attrs = %{attrs | owner_principal_uid: owner.uid}
      assert {:ok, _} = Ankole.Principals.create_agent(%{attrs | handle: "unlimited-one"})
      assert {:ok, _} = Ankole.Principals.create_agent(%{attrs | handle: "unlimited-two"})
      assert length(Ankole.Principals.list_agents()) == 2
    end)
  end

  test "only active Plugins contribute hooks and fixed Plugins stay active" do
    {:ok, optional} = Spec.from_module(Ankole.FeaturesTest.OptionalQuotaPlugin)
    assert optional.activation == :optional
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)
    {:ok, []} = Ankole.Plugins.put_enabled_ids([])

    assert {:ok, %{active: active, hooks: hooks}} =
             Registry.prepare_snapshot(modules: [Ankole.FeaturesTest.OptionalQuotaPlugin])

    assert active == %{}
    assert hooks == %{}

    assert {:ok, %{active: active}} =
             Registry.prepare_snapshot(modules: [Ankole.FeaturesTest.QuotaPlugin])

    assert Map.has_key?(active, "fixture-quota")

    assert {:ok, rows} = Ankole.ControlPlanePlugins.list()

    assert %{"active" => true, "configured_enabled" => true, "activation" => "always"} =
             Enum.find(rows, &(&1["id"] == "fixture-quota"))
  end

  test "an optional hook uses boot activation until a restart selects a new snapshot", %{
    tenant: tenant
  } do
    %{principal: owner} = human_fixture()
    provider = worker_provider_fixture()
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)
    {:ok, _} = Ankole.Plugins.put_enabled_ids(["fixture-optional-quota"])
    {:ok, active} = Registry.prepare_snapshot(modules: [Ankole.FeaturesTest.OptionalQuotaPlugin])
    Registry.update_for_test(fn _ -> active end)
    Process.put(:fixture_quotas, %{tenant.id => 0})

    attrs = %{
      handle: "boot-policy",
      display_name: "Fixture Agent",
      role: "Researcher",
      owner_principal_uid: owner.uid,
      worker_provider_id: provider.provider_id
    }

    assert {:error, :fixture_quota_exceeded} = Ankole.Principals.create_agent(attrs)
    {:ok, []} = Ankole.Plugins.put_enabled_ids([])
    assert {:error, :fixture_quota_exceeded} = Ankole.Principals.create_agent(attrs)

    {:ok, inactive} =
      Registry.prepare_snapshot(modules: [Ankole.FeaturesTest.OptionalQuotaPlugin])

    Registry.update_for_test(fn _ -> inactive end)
    assert {:ok, _} = Ankole.Principals.create_agent(attrs)
  end

  test "hook rejection rolls back invitation and routing-rule admission" do
    %{principal: agent} = agent_fixture()
    Process.put(:fixture_denied_hooks, [:enable_signal_binding])

    assert {:error, :fixture_denied} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "line", "fixture-hook", %{
               "config" => %{
                 "channelId" => "1650000001",
                 "channelSecret" => "fixture",
                 "channelAccessToken" => "fixture"
               },
               "group_message_mode" => "addressed_only"
             })

    assert_received {:fixture_hook, :enable_signal_binding, _, true}
    assert Ankole.Signals.get_binding!(agent.uid, "fixture-hook") == nil
    Process.put(:fixture_denied_hooks, [:create_invitation])
    %{principal: member} = human_fixture()

    assert {:error, :fixture_denied} =
             Ankole.Principals.create_invitation(member.uid, %{
               kind: :link,
               membership: :member,
               invited_email: nil,
               max_uses: 1,
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
             })

    assert Repo.aggregate(Ankole.Principals.Invitation, :count) == 0
  end

  test "binding quota checks admission while enabled routes can be edited and moved" do
    alias Ankole.Signals.Bindings
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    Process.put(:fixture_binding_limit, 1)

    attrs = %{
      "config" => %{
        "channelId" => "1650000001",
        "channelSecret" => "fixture",
        "channelAccessToken" => "fixture"
      },
      "group_message_mode" => "addressed_only"
    }

    assert {:ok, _} = Bindings.put_binding(first.uid, "line", "limited", attrs)

    assert_received {:fixture_hook_payload, :enable_signal_binding,
                     %{agent_uid: uid, name: "limited", adapter: "line", enabled: true} = payload}

    assert uid == first.uid
    assert payload.config_ref =~ "app-config://"
    refute Map.has_key?(payload, :definition)

    assert {:ok, _} = Bindings.put_binding(first.uid, "line", "limited", attrs)

    assert {:ok, %{binding: edited}} =
             Bindings.update_binding(first.uid, first.uid, "limited", %{
               "config" => %{},
               "group_message_mode" => "observe_all"
             })

    assert edited.unaddressed_group_message_policy == :record_only

    assert {:ok, %{binding: moved}} =
             Bindings.update_binding(first.uid, second.uid, "limited", %{"config" => %{}})

    assert moved.agent_uid == second.uid
    refute_received {:fixture_hook_payload, :enable_signal_binding, _}

    other = put_in(attrs, ["config", "channelId"], "1650000002")

    assert {:error, :fixture_binding_quota_exceeded} =
             Bindings.put_binding(first.uid, "line", "another", other)

    assert Ankole.Signals.get_binding!(first.uid, "another") == nil
    assert {:ok, _} = Bindings.disable_binding(second.uid, "limited")
    assert {:ok, _} = Bindings.put_binding(first.uid, "line", "another", other)

    assert {:error, :fixture_binding_quota_exceeded} =
             Bindings.update_binding(second.uid, second.uid, "limited", %{"config" => %{}})

    refute Ankole.Signals.get_binding!(second.uid, "limited").enabled
  end

  test "CloudEvent routes use the same admission payload and preserve enabled moves" do
    alias Ankole.Signals.{Bindings, Webhooks}
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        label: "Quota fixture",
        mode: "standing",
        event_format: "cloudevents",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    attrs = %{
      "config" => %{"webhook_endpoint_id" => endpoint.webhook_endpoint.id},
      "target" => %{"session_id" => "custom:quota"}
    }

    Process.put(:fixture_binding_limit, 1)
    assert {:ok, _} = Bindings.put_binding(first.uid, "cloudevents", "limited", attrs)

    assert_received {:fixture_hook_payload, :enable_signal_binding,
                     %{name: "limited", adapter: "cloudevents", enabled: true} = payload}

    assert payload.agent_uid == first.uid
    assert payload.config_ref =~ "webhook-endpoint://"
    assert {:ok, _} = Bindings.put_binding(first.uid, "cloudevents", "limited", attrs)

    assert {:ok, %{binding: edited}} =
             Bindings.update_binding(first.uid, first.uid, "limited", %{
               "config" => %{},
               "target" => %{"session_id" => "custom:edited"}
             })

    assert edited.target == %{"session_id" => "custom:edited"}

    assert {:ok, %{binding: moved}} =
             Bindings.update_binding(first.uid, second.uid, "limited", %{"config" => %{}})

    assert moved.agent_uid == second.uid
    refute_received {:fixture_hook_payload, :enable_signal_binding, _}

    assert {:error, :fixture_binding_quota_exceeded} =
             Bindings.put_binding(first.uid, "cloudevents", "another", attrs)

    assert Ankole.Signals.get_binding!(first.uid, "limited") == nil
    assert {:ok, _} = Bindings.disable_binding(second.uid, "limited")
    assert {:ok, _} = Bindings.put_binding(second.uid, "cloudevents", "limited", attrs)

    assert_received {:fixture_hook_payload, :enable_signal_binding,
                     %{agent_uid: _, name: "limited"}}
  end

  defp policy(value) do
    {:ok, _} = AppConfigure.put_global_by_key("features.fixture.experiment", value)
    AppConfigure.Cache.clear_for_test()
  end
end
