defmodule Ankole.AIAgent.LarkSkillEnablementTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.Registry, as: PluginsRegistry
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.ActorRuntime.BindingWorkerEnv

  @lark_skills ~w(lark-im lark-office-suite lark-oa)

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_definitions(Config.app_config_definitions())
    :ok = AppConfigure.register_patterns(Config.app_config_patterns())
    assert {:ok, %{skills: 12}} = Library.sync_builtin_skills(force: true)

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
      AppConfigureCache.clear_for_test()
    end)

    :ok
  end

  test "an available Lark signal binding enables the three bot skills without mutating stored flags" do
    %{principal: agent} = agent_fixture()

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == []
    assert {:error, :skill_not_enabled} = Library.skill_view(agent.uid, "lark-im")

    assert Enum.all?(@lark_skills, fn skill_name ->
             match?(
               %AgentSkill{enabled: false, default_enabled: false},
               Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: skill_name)
             )
           end)

    binding = lark_binding!(agent.uid)

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == Enum.sort(@lark_skills)

    assert {:ok, _skill} = Library.skill_view(agent.uid, "lark-office-suite")

    assert Enum.all?(@lark_skills, fn skill_name ->
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: skill_name).enabled ==
               false
           end)

    assert {:ok, _binding} =
             binding
             |> Binding.changeset(%{unavailable_reason: "credentials_revoked"})
             |> Repo.update()

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == []
  end

  test "the global escape hatch restores ordinary per-agent skill enablement" do
    %{principal: agent} = agent_fixture()
    binding = lark_binding!(agent.uid)
    definition = Config.auto_enable_lark_skills_definition()

    assert {:ok, _value} = AppConfigure.put_global(definition, false)
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == []

    assert {:ok, %AgentSkill{enabled: true}} =
             Library.set_agent_skill_enabled(agent.uid, "lark-im", true)

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == ["lark-im"]

    assert {:ok, _binding} =
             binding
             |> Binding.changeset(%{enabled: false})
             |> Repo.update()

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == ["lark-im"]

    assert {:ok, _value} = AppConfigure.put_global(definition, true)
    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == []

    assert Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "lark-im").enabled
  end

  test "a disabled Lark plugin fails closed even when a stale binding remains" do
    %{principal: agent} = agent_fixture()
    _binding = lark_binding!(agent.uid)
    registry = start_registry!([])

    assert {:ok, %AgentSkill{enabled: true}} =
             Library.set_agent_skill_enabled(agent.uid, "lark-im", true)

    assert {:ok, skills} =
             Library.enabled_skills_for_agent(agent.uid, plugin_registry: registry)

    assert lark_skill_names(skills) == []

    assert {:error, :skill_not_enabled} =
             Library.skill_view(agent.uid, "lark-im", nil, plugin_registry: registry)
  end

  test "a binding with a custom base URL remains signal-only" do
    %{principal: agent} = agent_fixture()
    _binding = lark_binding!(agent.uid, %{"baseURL" => "http://lark.test.local"})

    assert {:ok, skills} = Library.enabled_skills_for_agent(agent.uid)
    assert lark_skill_names(skills) == []
    assert {:ok, %{}} = BindingWorkerEnv.resolve(agent.uid)
  end

  defp lark_binding!(agent_uid, overrides \\ %{}) do
    config =
      Map.merge(
        %{
          "appID" => "cli-#{agent_uid}",
          "appSecret" => "app-secret",
          "domain" => "feishu",
          "platformSubjectNamespace" => "lark-main",
          "userName" => "Lark Bot"
        },
        overrides
      )

    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(agent_uid, "lark", "lark-main", %{
               "config" => config,
               "group_message_mode" => "addressed_only"
             })

    binding
  end

  defp lark_skill_names(skills) do
    skills
    |> Enum.map(& &1["skill_name"])
    |> Enum.filter(&(&1 in @lark_skills))
  end

  defp start_registry!(modules) do
    name = :"lark_skill_enablement_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {PluginsRegistry, name: name, discovery: [paths: [], modules: modules]},
      id: name
    )

    name
  end
end
