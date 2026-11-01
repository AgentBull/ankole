defmodule AnkoleWeb.AgentLibraryCapabilityControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.AgentWorkers.WorkerRoute

  setup do
    AppConfigureRegistry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
    end)

    :ok
  end

  test "global defaults and Agent three-state overrides preserve parent and child state independently",
       %{
         conn: conn
       } do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    global = conn |> api(:get, ~p"/api/v2/agent-library/capabilities") |> json_response(200)

    assert Enum.find(global["agent_plugins"], &(&1["id"] == "github"))[
             "effective_enabled"
           ] == false

    assert Enum.find(global["agent_plugins"], &(&1["id"] == "lark"))["effective_enabled"] == false

    standalone_names = Enum.map(global["skills"], & &1["name"])
    assert "pdf" in standalone_names
    refute "lark-im" in standalone_names
    refute "docx" in standalone_names

    agent_view =
      conn
      |> recycle_api()
      |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-capabilities")
      |> json_response(200)

    lark = plugin(agent_view, "lark")
    assert lark["global_default_enabled"] == false
    assert lark["override_enabled"] == nil
    assert lark["effective_enabled"] == false
    assert Enum.all?(lark["skills"], &(&1["effective_enabled"] == false))

    enabled =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => true
      })
      |> json_response(200)

    assert plugin(enabled, "lark")["effective_enabled"] == true

    child_disabled =
      conn
      |> recycle_api()
      |> api(
        :put,
        ~p"/api/v2/agents/#{agent.uid}/library-capabilities/skills/lark:lark-im",
        %{"enabled" => false}
      )
      |> json_response(200)

    assert skill(plugin(child_disabled, "lark"), "lark-im")["override_enabled"] == false
    assert skill(plugin(child_disabled, "lark"), "lark-im")["effective_enabled"] == false

    parent_disabled =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => false
      })
      |> json_response(200)

    assert skill(plugin(parent_disabled, "lark"), "lark-im")["override_enabled"] == false

    parent_enabled_again =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => true
      })
      |> json_response(200)

    assert skill(plugin(parent_enabled_again, "lark"), "lark-im")["effective_enabled"] == false

    inherited =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => nil
      })
      |> json_response(200)

    assert plugin(inherited, "lark")["override_enabled"] == nil
    assert plugin(inherited, "lark")["effective_enabled"] == false

    global_lark_enabled =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agent-library/agent-plugins/lark", %{
        "enabled" => true,
        "defaults_scope" => "tenant"
      })
      |> json_response(200)

    assert plugin(global_lark_enabled, "lark")["effective_enabled"] == true

    inherited_enabled =
      conn
      |> recycle_api()
      |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-capabilities")
      |> json_response(200)

    assert plugin(inherited_enabled, "lark")["effective_enabled"] == true
    assert skill(plugin(inherited_enabled, "lark"), "lark-im")["override_enabled"] == false
  end

  test "Agent-private installed Skills appear only in that Agent's standalone list", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    drive_file_fixture(agent.uid, "skills/private-notes/SKILL.md", """
    ---
    name: private-notes
    description: Private notes Skill.
    ---
    Take notes.
    """)

    response =
      conn
      |> console_conn()
      |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-capabilities")
      |> json_response(200)

    private = Enum.find(response["skills"], &(&1["id"] == "private-notes"))
    assert private["source_kind"] == "installed"
    assert private["effective_enabled"] == true
  end

  test "Job creation accepts one enabled workspace template and rejects unavailable templates" do
    %{principal: agent} = background_agent_fixture()

    assert {:error, {:agent_plugin_disabled, "lark"}} =
             create_job(agent.uid, "lark-disabled", "lark")

    assert {:ok, _override} = AgentPlugins.set_agent_override(agent.uid, "lark", true)

    assert {:error, {:agent_plugin_has_no_workspace_template, "lark"}} =
             create_job(agent.uid, "lark-enabled", "lark")

    assert {:ok, %{job: existing_job}} =
             create_job(agent.uid, "deep-research-before-change", "deep-research")

    assert existing_job.workspace_template_id == "deep-research"

    assert {:ok, _defaults} =
             AgentPlugins.set_global_skill_default("deep-research:create-deep-research", false)

    assert Repo.reload!(existing_job).workspace_template_id == "deep-research"

    assert {:ok, %{"agent_plugins" => catalog}} = Library.runtime_catalog_for_agent(agent.uid)
    current = Enum.find(catalog, &(&1["id"] == "deep-research"))
    assert current["id"] == "deep-research"
    assert current["skills"] == []

    assert {:ok, %{job: changed_job}} =
             create_job(agent.uid, "deep-research-after-change", "deep-research")

    assert changed_job.workspace_template_id == "deep-research"

    assert {:ok, _override} = AgentPlugins.set_agent_override(agent.uid, "deep-research", false)

    assert {:error, {:agent_plugin_disabled, "deep-research"}} =
             create_job(agent.uid, "deep-research-disabled", "deep-research")

    assert Repo.reload!(existing_job).workspace_template_id == "deep-research"
  end

  test "capability endpoints require a browser session and reject missing resources", %{
    conn: conn
  } do
    assert conn |> api(:get, ~p"/api/v2/agent-library/capabilities") |> json_response(401)

    conn = console_conn(conn)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> api(:put, ~p"/api/v2/agent-library/agent-plugins/missing", %{
               "enabled" => true,
               "defaults_scope" => "tenant"
             })
             |> json_response(404)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> recycle_api()
             |> api(:get, ~p"/api/v2/agents/missing-agent/library-capabilities")
             |> json_response(404)
  end

  test "a Skill disable sends one scoped control to each active Job turn", %{conn: conn} do
    %{principal: agent} = background_agent_fixture()
    {:ok, profile} = Ankole.AIGateway.ModelProfiles.get_model_profile(agent.uid, "coding")

    :ok =
      Ankole.SessionsCase.cache_actor_runtime_models(profile["provider_id"])

    route = "agent-library-skill-disable-#{System.unique_integer([:positive])}"
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    assert {:ok, %{job: job}} = create_job(agent.uid, "skill-disable", nil)
    assert job.authorization_kind == "service"

    event =
      Repo.get_by!(Ankole.Signals.Signal,
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        type: "background_agent_job.dispatch"
      )

    assert event.authorization_kind == job.authorization_kind

    assert {:ok, _driver} =
             Ankole.Sessions.ensure_driver(%{
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(job.id)
             })

    assert_receive {:actor_lane, %{body: {:turn_start, _}}}, 2_000

    response =
      conn
      |> console_conn()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-capabilities/skills/pdf", %{
        "enabled" => false
      })
      |> json_response(200)

    assert Enum.find(response["skills"], &(&1["id"] == "pdf"))["effective_enabled"] == false
    assert_receive {:actor_lane, %{body: {:turn_control, control}}}, 2_000
    assert control.command == "skill_disabled"
    assert Torque.decode!(control.payload_json) == %{"skill_names" => ["pdf"]}

    defaults_key = "ai_agent.library.skill_defaults"

    assert {:ok, _defaults} =
             Ankole.AppConfigure.put_tenant_by_key(defaults_key, %{"ocr" => true})

    assert {:ok, %{skills: %{"ocr" => true}}} =
             Ankole.AIAgent.Library.AgentPlugins.Config.defaults()

    assert {:ok, %{value: %{"value" => %{"ocr" => false}}}} =
             Repo.transact(fn ->
               Ankole.Ash.create(Ankole.AppConfigure.AppConfig, :put, %{
                 scope: "tenant:" <> Repo.tenant_id!(),
                 key: defaults_key,
                 input: %{"ocr" => false}
               })
             end)

    assert {:ok, %{skills: %{"ocr" => true}}} =
             Ankole.AIAgent.Library.AgentPlugins.Config.defaults()

    assert {:ok, cached_capabilities} = Library.capabilities_for_agent(agent.uid)
    assert Enum.find(cached_capabilities["skills"], &(&1["id"] == "ocr"))["effective_enabled"]

    assert :ok = Ankole.AIAgent.Library.RuntimeCapabilityChanges.notify_global({:skill, "ocr"})
    assert_receive {:actor_lane, %{body: {:turn_control, global_control}}}, 2_000
    assert global_control.command == "skill_disabled"
    assert Torque.decode!(global_control.payload_json) == %{"skill_names" => ["ocr"]}
    refute_receive {:actor_lane, _envelope}
  end

  defp plugin(capabilities, id), do: Enum.find(capabilities["agent_plugins"], &(&1["id"] == id))
  defp skill(plugin, name), do: Enum.find(plugin["skills"], &(&1["name"] == name))

  defp create_job(agent_uid, suffix, workspace_template_id) do
    BackgroundAgentJobs.create_with_dispatch(%{
      "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
      "agent_uid" => agent_uid,
      "owner_session_id" => "parent-session-#{suffix}",
      "source_tool_call_id" => "tool-#{suffix}",
      "workspace_template_id" => workspace_template_id,
      "title" => "Job #{suffix}",
      "task" => "Complete #{suffix}.",
      "reply_route" => %{"binding_name" => "lark"}
    })
  end

  defp api(conn, method, path, data \\ nil) do
    conn =
      if get_req_header(conn, "x-csrf-token") == [], do: recycle(conn), else: recycle_api(conn)

    conn =
      conn
      |> delete_req_header("content-type")
      |> put_req_header("accept", "application/vnd.api+json")

    conn =
      if data, do: put_req_header(conn, "content-type", "application/vnd.api+json"), else: conn

    dispatch(conn, @endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
