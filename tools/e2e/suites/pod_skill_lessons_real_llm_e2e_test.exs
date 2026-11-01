defmodule Ankole.E2E.PodSkillLessonsRealLLMTest do
  @moduledoc "A Pod-only Agent learns Skill lessons through real models and its Docker Worker."

  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.Harness

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AuthZ.Actor
  alias Ankole.E2E.PodContentStory
  alias Ankole.E2E.Scenarios.SkillLesson
  alias Ankole.Principals.Agent
  alias Ankole.Signals.Binding

  @main_model "deepseek/deepseek-v4.1-flash"

  setup_all do
    start_committed_repo!()
  end

  setup do
    cleanup_committed_fixtures_on_exit!()
    :ok
  end

  @tag :real_llm
  @tag :pod_skill_lessons_real_llm
  @tag timeout: 1_500_000
  test "native Human work produces a reflection and delivered lessons without external Bindings",
       %{
         tenant: tenant
       } do
    refute Repo.exists?(Binding)
    ctx = start_native_worker!(tenant)
    refute Repo.exists?(Binding)

    %{lessons: lessons} = SkillLesson.run_real_pod_skill_lesson_reflection_loop(ctx)

    assert lessons != []
    assert Enum.all?(lessons, &(&1.author_kind == :dreaming))
    refute Repo.exists?(Binding)
  end

  defp start_native_worker!(tenant) do
    %{principal: agent} =
      create_e2e_agent!(%{
        display_name: "Pod Skill Lessons Agent",
        role: "Complete native Pod work and learn from its execution evidence."
      })

    provider_id = "pod-lessons-#{Ecto.UUID.generate()}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => openrouter_api_key!()}]
               }
             })

    for profile <- ["primary", "light"] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: @main_model
               })
    end

    owner_uid = Repo.get_by!(Agent, uid: agent.uid).owner_principal_uid
    assert {:ok, owner} = Ankole.Principals.get_principal(owner_uid)

    for {resource, action} <- [
          {"agent:#{agent.uid}", "chat"},
          {"agent:#{agent.uid}:tool:*", "invoke"}
        ] do
      assert {:ok, _grant} =
               Ankole.AuthZ.upsert_permission_grant(%{
                 principal_uid: owner_uid,
                 resource_pattern: resource,
                 action: action
               })
    end

    worker = start_worker!([agent.uid])
    PodContentStory.configure_browser_origin!(worker.server_port, tenant)

    Map.merge(worker, %{
      agent: agent,
      owner_uid: owner_uid,
      owner_actor: Actor.new(owner),
      provider_id: provider_id,
      tenant: tenant
    })
  end
end
