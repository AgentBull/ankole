defmodule Ankole.AIGateway.ModelProfilesTest do
  use Ankole.AIGatewayCase, async: false

  alias Ankole.AIGateway.CodexModels
  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.Resolver
  alias Ankole.AppConfigure

  test "runtime selectors reuse cached layer reads and observe configuration writes" do
    provider_id = provider("openai")
    %{principal: agent} = agent_fixture()

    for profile <- ModelProfiles.agent_profiles(),
        do: ModelProfiles.put_model_profile(agent.uid, profile, nil)

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "gpt-5"
             })

    Ankole.AppConfigure.Cache.clear_for_test()
    handler = "model-profile-query-count"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and
               metadata.source in ["app_configurations", "site_app_configurations"] do
            Process.put(:model_profile_reads, Process.get(:model_profile_reads, 0) + 1)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = CodexModels.manifest(agent.uid, "agent")
    assert Process.get(:model_profile_reads) == 20
    Process.put(:model_profile_reads, 0)

    assert {:ok, _} = ModelProfiles.get_model_profile(agent.uid, "primary")
    assert {:ok, _} = ModelProfiles.provider_hosted_capabilities(agent.uid)
    assert {:ok, _} = ModelProfiles.list_custom_model_profiles(agent.uid)
    assert {:ok, _} = CodexModels.manifest(agent.uid, "agent")
    assert Process.get(:model_profile_reads) == 0

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "gpt-5-mini"
             })

    assert {:ok, %{"model" => "gpt-5-mini"}} =
             ModelProfiles.get_model_profile(agent.uid, "primary")
  end

  test "same-slot inheritance precedes light and coding fallbacks" do
    provider_id = provider("openai")
    %{principal: agent} = agent_fixture()

    for profile <- ModelProfiles.agent_profiles() do
      assert {:ok, _result} = ModelProfiles.put_model_profile(agent.uid, profile, nil)
    end

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:global, "primary", %{
               provider_id: provider_id,
               model: "site-primary"
             })

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "pod-primary"
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "agent-primary"
             })

    assert {:ok, configuration} = ModelProfiles.model_profile_configuration(agent.uid)

    assert %{
             value: %{"model" => "agent-primary"},
             source: :agent,
             resolved_from_profile: "primary"
           } = configuration.effective["light"]

    assert %{
             value: %{"model" => "agent-primary"},
             source: :agent,
             resolved_from_profile: "primary"
           } = configuration.effective["coding"]

    assert %{value: %{"model" => "pod-primary"}, source: :tenant} =
             configuration.inherited["primary"]

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "light", %{
               provider_id: provider_id,
               model: "pod-light"
             })

    assert {:ok, configuration} = ModelProfiles.model_profile_configuration(agent.uid)

    assert %{
             value: %{"model" => "pod-light"},
             source: :tenant,
             resolved_from_profile: "light"
           } = configuration.effective["light"]

    assert {:ok, system} = Ankole.Principals.system_principal()
    assert {:ok, light} = ModelProfiles.get_model_profile(system.uid, "light")
    assert light["model"] == "pod-light"
  end

  test "a sparse Agent exposes inherited and fallback selectors in both model catalogs" do
    provider_id = provider("openai")
    %{principal: agent} = agent_fixture()

    for profile <- ModelProfiles.agent_profiles() do
      assert {:ok, _result} = ModelProfiles.put_model_profile(agent.uid, profile, nil)
    end

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "gpt-5"
             })

    assert {:ok, configuration} = ModelProfiles.model_profile_configuration(agent.uid)
    assert configuration.overrides == %{}

    assert {:ok, profiles} = ModelProfiles.get_model_profiles(agent.uid)
    assert profiles["primary"]["model"] == "gpt-5"
    assert profiles["light"]["fallback_profile"] == "primary"
    assert profiles["coding"]["fallback_profile"] == "primary"

    assert {:ok, %{"data" => entries}} = Models.list_models(agent.uid, "agent")
    selectors = MapSet.new(entries, & &1["id"])
    assert MapSet.subset?(MapSet.new(["primary", "light", "coding"]), selectors)

    assert {:ok, %{"models" => manifest}} = CodexModels.manifest(agent.uid, "agent")
    slugs = MapSet.new(manifest, & &1["slug"])
    assert MapSet.subset?(MapSet.new(["primary", "light", "coding", "gpt-5"]), slugs)
  end

  test "Agent and Pod rerank names stay in separate capability namespaces" do
    provider_id = provider("openrouter")
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "rerank", %{
               description: "Agent LLM alias",
               provider_id: provider_id,
               model: "agent-llm"
             })

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "rerank", %{
               provider_id: provider_id,
               model: "pod-rerank"
             })

    assert ModelProfiles.custom_profile_name?("rerank")
    assert ModelProfiles.profile_capability("rerank") == {:ok, "llm"}

    assert {:ok, agent_runtime} =
             Resolver.resolve_request_model(agent.uid, "llm", %{"model" => "rerank"})

    assert agent_runtime["model"] == "agent-llm"

    assert {:ok, pod_runtime} =
             Resolver.resolve_request_model(agent.uid, "rerank", %{"model" => "default"})

    assert pod_runtime["model"] == "pod-rerank"
  end

  test "default overrides reject nil and restore inheritance by deleting rows" do
    provider_id = provider("openai")

    assert {:error, _reason} =
             AppConfigure.put_tenant_by_key("ai_gateway.model_profiles.primary", nil)

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:global, "primary", %{
               provider_id: provider_id,
               model: "site-primary"
             })

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "pod-primary"
             })

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_default_model_profile(:tenant, "primary", nil)

    assert :error =
             AppConfigure.get_override_by_key(:tenant, "ai_gateway.model_profiles.primary")

    assert {:ok, configuration} = ModelProfiles.defaults_model_profile_configuration(:tenant)

    assert %{value: %{"model" => "site-primary"}, source: :global} =
             configuration.effective["primary"]

    assert {:ok, _} =
             ModelProfiles.put_default_provider_hosted_capabilities(:tenant, %{
               "web_search" => false
             })

    assert {:ok, _} =
             ModelProfiles.put_default_provider_hosted_capabilities(:tenant, %{
               "web_search" => nil
             })

    assert :error =
             AppConfigure.get_override_by_key(
               :tenant,
               "ai_gateway.provider_hosted.web_search"
             )
  end

  test "system Principals inherit each Pod slot and keep their overrides independent" do
    provider_id = provider("openrouter")

    for slot <- ModelProfiles.pod_profiles() do
      assert {:ok, _} =
               AppConfigure.put_global_by_key(ModelProfiles.profile_key(slot), %{
                 "provider_id" => provider_id,
                 "model" => "site-#{slot}"
               })

      assert {:ok, _} =
               AppConfigure.put_tenant_by_key(ModelProfiles.profile_key(slot), %{
                 "provider_id" => provider_id,
                 "model" => "pod-#{slot}"
               })
    end

    assert {:ok, defaults} = ModelProfiles.defaults_model_profile_configuration(:tenant)

    for uid <- Ankole.Principals.SystemServices.uids() do
      assert {:ok, config} = ModelProfiles.model_profile_configuration(uid)
      assert config.overrides == %{}
      assert config.effective == defaults.effective
      assert config.provider_hosted == defaults.provider_hosted
    end

    for slot <- ModelProfiles.pod_profiles() do
      assert {:ok, _} =
               AppConfigure.put_system_by_key("ankole_brain", ModelProfiles.profile_key(slot), %{
                 "provider_id" => provider_id,
                 "model" => "brain-#{slot}"
               })
    end

    assert {:ok, brain} = ModelProfiles.model_profile_configuration("ankole_brain")
    assert {:ok, applet} = ModelProfiles.model_profile_configuration("system")
    assert applet.effective == defaults.effective

    for slot <- ModelProfiles.pod_profiles() do
      assert brain.effective[slot].value["model"] == "brain-#{slot}"
      assert brain.effective[slot].source == :system
      assert brain.inherited[slot] == defaults.effective[slot]
    end

    assert {:ok, _} = ModelProfiles.put_system_model_profile("ankole_brain", "light", nil)

    assert :error =
             AppConfigure.get_override_by_key(
               {:system, "ankole_brain"},
               ModelProfiles.profile_key("light")
             )

    assert {:ok, %{"model" => "pod-light"}} =
             ModelProfiles.get_model_profile("ankole_brain", "light")
  end

  test "system same-slot inheritance precedes fallbacks, including Brain heavy" do
    provider_id = provider("openrouter")
    attrs = fn model -> %{provider_id: provider_id, model: model} end

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:global, "primary", attrs.("site-primary"))

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "heavy", attrs.("pod-heavy"))

    assert {:ok, _} =
             ModelProfiles.put_system_model_profile(
               "ankole_brain",
               "primary",
               attrs.("brain-primary")
             )

    assert {:ok, %{"model" => "brain-primary"}} =
             ModelProfiles.get_model_profile("ankole_brain", "light")

    assert {:ok, %{"model" => "pod-heavy"}} =
             ModelProfiles.get_model_profile("ankole_brain", "coding")

    assert Ankole.Brain.Config.dreaming_model()["model"] == "pod-heavy"

    assert {:ok, _} =
             ModelProfiles.put_system_model_profile(
               "ankole_brain",
               "heavy",
               attrs.("brain-heavy")
             )

    assert Ankole.Brain.Config.dreaming_model()["model"] == "brain-heavy"
    assert {:ok, _} = ModelProfiles.put_system_model_profile("ankole_brain", "heavy", nil)
    assert {:ok, _} = ModelProfiles.put_default_model_profile(:tenant, "heavy", nil)
    assert Ankole.Brain.Config.dreaming_model()["model"] == "brain-primary"

    assert {:ok, %{"model" => "brain-primary"}} =
             ModelProfiles.get_model_profile("ankole_brain", "coding")
  end

  test "rerank selectors respect system overrides while Agent and Human calls use Pod defaults" do
    provider_id = provider("openrouter")
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    assert {:ok, _} =
             ModelProfiles.put_default_model_profile(:tenant, "rerank", %{
               provider_id: provider_id,
               model: "pod-rerank"
             })

    assert {:ok, _} =
             ModelProfiles.put_system_model_profile("ankole_brain", "rerank", %{
               provider_id: provider_id,
               model: "brain-rerank"
             })

    assert {:ok, _} =
             ModelProfiles.put_system_model_profile("system", "rerank", %{
               provider_id: provider_id,
               model: "system-rerank"
             })

    for selector <- ["default", "rerank.default"],
        {uid, model} <- [
          {"ankole_brain", "brain-rerank"},
          {"system", "system-rerank"},
          {agent.uid, "pod-rerank"},
          {human.uid, "pod-rerank"}
        ] do
      assert {:ok, runtime} =
               Resolver.resolve_request_model(uid, "rerank", %{"model" => selector})

      assert runtime["model"] == model
    end

    assert Ankole.Brain.Config.rerank_model()["model"] == "brain-rerank"
  end

  test "system settings reject unknown identities, non-slot keys, and stored nil" do
    pattern =
      AppConfigure.define_pattern(
        id: "system-test-pattern",
        key_pattern: ~r/\Asystem-test-pattern\.[a-z]+\z/,
        encrypted: false,
        scope: :tenant,
        schema: Ankole.AppConfigure.Schema.non_empty_string()
      )

    assert :ok = Ankole.AppConfigure.Registry.register_patterns([pattern])

    assert {:error, {:invalid_system_configuration_key, "system-test-pattern"}} =
             AppConfigure.put_system_by_key("system", "system-test-pattern.key", "value")

    assert {:error, :unknown_system_principal} =
             ModelProfiles.system_model_profile_configuration("invented")

    assert {:error, :unknown_system_principal} =
             ModelProfiles.put_system_model_profile("invented", "primary", nil)

    assert {:error, :unknown_system_principal} =
             AppConfigure.get_override_by_key(
               {:system, "invented"},
               ModelProfiles.profile_key("primary")
             )

    assert {:error, :invalid_model_profile} =
             ModelProfiles.put_system_model_profile("system", "custom", %{})

    assert {:error, {:invalid_system_configuration_key, _}} =
             AppConfigure.put_system_by_key(
               "system",
               "ai_gateway.provider_hosted.web_search",
               false
             )

    assert {:error, _} =
             AppConfigure.put_system_by_key("system", ModelProfiles.profile_key("primary"), nil)
  end

  test "system overrides are tenant-scoped and Provider references identify each tenant", %{
    tenant: tenant
  } do
    provider_id = provider("openrouter")
    other = Ankole.DataCase.create_tenant()

    assert {:ok, _} =
             ModelProfiles.put_system_model_profile("ankole_brain", "light", %{
               provider_id: provider_id,
               model: "brain-only"
             })

    assert {:ok, config} =
             Repo.with_tenant(other.id, fn ->
               ModelProfiles.system_model_profile_configuration("ankole_brain")
             end)

    assert config.overrides == %{}

    assert {:ok, _} =
             Repo.with_tenant(other.id, fn ->
               ModelProfiles.put_system_model_profile("ankole_brain", "light", %{
                 provider_id: provider_id,
                 model: "other-brain"
               })
             end)

    assert {:error, {:provider_in_use, references}} = ProviderConfigs.delete_provider(provider_id)

    assert Enum.sort(references) ==
             Enum.sort([
               "tenant:#{tenant.id}:system:ankole_brain:ai_gateway.model_profiles.light",
               "tenant:#{other.id}:system:ankole_brain:ai_gateway.model_profiles.light"
             ])

    assert {:ok, _} = ModelProfiles.put_system_model_profile("ankole_brain", "light", nil)

    assert {:error, {:provider_in_use, [_reference]}} =
             ProviderConfigs.delete_provider(provider_id)

    assert {:ok, _} =
             Repo.with_tenant(other.id, fn ->
               ModelProfiles.put_system_model_profile("ankole_brain", "light", nil)
             end)

    assert {:ok, _} = ProviderConfigs.delete_provider(provider_id)
  end

  defp provider(kind) do
    provider_id = "model-profiles-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: kind,
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    provider_id
  end
end
