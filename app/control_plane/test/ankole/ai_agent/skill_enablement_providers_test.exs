defmodule Ankole.AIAgent.SkillEnablementProvidersTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.SkillEnablementProviders
  alias Ankole.Plugins.Registry

  defmodule ProjectedProvider do
    @moduledoc false

    @behaviour Ankole.AIAgent.Library.SkillEnablementProvider

    alias Ankole.AIAgent.Library.SkillEnablementProvider.Context

    @impl true
    def resolve(%Context{agent_uid: "enabled-agent"}), do: {:ok, {:projected, true}}
    def resolve(%Context{}), do: {:ok, {:projected, false}}
  end

  defmodule ManualProvider do
    @moduledoc false

    @behaviour Ankole.AIAgent.Library.SkillEnablementProvider

    alias Ankole.AIAgent.Library.SkillEnablementProvider.Context

    @impl true
    def resolve(%Context{}), do: {:ok, :manual}
  end

  defmodule InvalidProvider do
    @moduledoc false

    @behaviour Ankole.AIAgent.Library.SkillEnablementProvider

    alias Ankole.AIAgent.Library.SkillEnablementProvider.Context

    @impl true
    def resolve(%Context{}), do: :enabled
  end

  defmodule ProviderPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.AIAgent.SkillEnablementProvidersTest.InvalidProvider
    alias Ankole.AIAgent.SkillEnablementProvidersTest.ManualProvider
    alias Ankole.AIAgent.SkillEnablementProvidersTest.ProjectedProvider

    @impl true
    def plugin_id, do: "skill-provider-test"

    @impl true
    def api_version, do: 1

    @impl true
    def adapter_declarations do
      [
        declaration("projected-profile", ProjectedProvider),
        declaration("manual-profile", ManualProvider),
        declaration("invalid-profile", InvalidProvider)
      ]
    end

    defp declaration(id, module) do
      %{
        contract_id: "ai_agent.library.skill_enablement_provider",
        id: id,
        plugin_id: plugin_id(),
        module: module
      }
    end
  end

  test "combines provider modes with persisted flags and fails closed when a provider is absent" do
    registry = start_registry!([ProviderPlugin])

    skills = [
      skill("projected", false, "projected-profile"),
      skill("manual-enabled", true, "manual-profile"),
      skill("manual-disabled", false, "manual-profile"),
      skill("missing-provider", true, "missing-profile"),
      skill("ordinary", true),
      skill("installed", true, "missing-profile", "installed")
    ]

    assert {:ok, enabled} =
             SkillEnablementProviders.filter_enabled("enabled-agent", skills,
               plugin_registry: registry
             )

    assert Enum.map(enabled, & &1.skill_name) ==
             ~w(projected manual-enabled ordinary installed)

    assert {:ok, disabled_agent_skills} =
             SkillEnablementProviders.filter_enabled("disabled-agent", skills,
               plugin_registry: registry
             )

    assert Enum.map(disabled_agent_skills, & &1.skill_name) ==
             ~w(manual-enabled ordinary installed)
  end

  test "rejects invalid provider results instead of falling back to persisted enablement" do
    registry = start_registry!([ProviderPlugin])
    skill = skill("invalid", true, "invalid-profile")

    assert {:error, {:invalid_skill_enablement_provider_result, "invalid-profile", :enabled}} =
             SkillEnablementProviders.enabled?("enabled-agent", skill, plugin_registry: registry)
  end

  defp skill(name, enabled, execution_profile \\ nil, source_kind \\ "builtin") do
    metadata =
      case execution_profile do
        nil -> %{}
        profile -> %{"execution_profile" => profile}
      end

    %AgentSkill{
      skill_name: name,
      source_kind: source_kind,
      enabled: enabled,
      metadata: metadata
    }
  end

  defp start_registry!(modules) do
    name = :"skill_enablement_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, name: name, discovery: [paths: [], modules: modules]},
      id: name
    )

    name
  end
end
