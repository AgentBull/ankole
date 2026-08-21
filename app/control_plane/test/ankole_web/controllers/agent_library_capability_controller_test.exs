defmodule AnkoleWeb.AgentLibraryCapabilityControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.AuthZ
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
      AppConfigureCache.clear_for_test()
    end)

    :ok
  end

  test "global defaults and Agent three-state overrides preserve parent and child state independently",
       %{
         conn: conn
       } do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    global = conn |> get(~p"/api/v1/agent-library/capabilities") |> json_response(200)

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
      |> get(~p"/api/v1/agents/#{agent.uid}/library-capabilities")
      |> json_response(200)

    lark = plugin(agent_view, "lark")
    assert lark["global_default_enabled"] == false
    assert lark["override_enabled"] == nil
    assert lark["effective_enabled"] == false
    assert Enum.all?(lark["skills"], &(&1["effective_enabled"] == false))

    enabled =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => true
      })
      |> json_response(200)

    assert plugin(enabled, "lark")["effective_enabled"] == true

    child_disabled =
      conn
      |> recycle_api()
      |> put(
        ~p"/api/v1/agents/#{agent.uid}/library-capabilities/skills/lark:lark-im",
        %{"enabled" => false}
      )
      |> json_response(200)

    assert skill(plugin(child_disabled, "lark"), "lark-im")["override_enabled"] == false
    assert skill(plugin(child_disabled, "lark"), "lark-im")["effective_enabled"] == false

    parent_disabled =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => false
      })
      |> json_response(200)

    assert skill(plugin(parent_disabled, "lark"), "lark-im")["override_enabled"] == false

    parent_enabled_again =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => true
      })
      |> json_response(200)

    assert skill(plugin(parent_enabled_again, "lark"), "lark-im")["effective_enabled"] == false

    inherited =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-capabilities/agent-plugins/lark", %{
        "enabled" => nil
      })
      |> json_response(200)

    assert plugin(inherited, "lark")["override_enabled"] == nil
    assert plugin(inherited, "lark")["effective_enabled"] == false

    global_lark_enabled =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agent-library/agent-plugins/lark", %{"enabled" => true})
      |> json_response(200)

    assert plugin(global_lark_enabled, "lark")["effective_enabled"] == true

    inherited_enabled =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/library-capabilities")
      |> json_response(200)

    assert plugin(inherited_enabled, "lark")["effective_enabled"] == true
    assert skill(plugin(inherited_enabled, "lark"), "lark-im")["override_enabled"] == false
  end

  test "Agent-private installed Skills appear only in that Agent's standalone list", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _sync} =
             Library.replace_installed_skill_observations(agent.uid, [
               %{
                 skill_name: "private-notes",
                 description: "Private notes Skill.",
                 default_enabled: true,
                 tags: [],
                 disable_model_invocation: false
               }
             ])

    response =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/agents/#{agent.uid}/library-capabilities")
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

    assert {:ok, catalog} = AgentPlugins.enabled_catalog_for_agent(agent.uid)
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

  test "capability endpoints require a bearer token and reject missing resources", %{conn: conn} do
    assert conn |> get(~p"/api/v1/agent-library/capabilities") |> json_response(401)

    conn = bearer_conn(conn)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> put(~p"/api/v1/agent-library/agent-plugins/missing", %{"enabled" => true})
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/agents/missing-agent/library-capabilities")
             |> json_response(404)
  end

  test "a Skill disable sends one scoped control to each active Job turn", %{conn: conn} do
    %{principal: agent} = background_agent_fixture()
    route = "agent-library-skill-disable-#{System.unique_integer([:positive])}"
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)

    assert {:ok, %{job: job, dispatch_event: event}} = create_job(agent.uid, "skill-disable", nil)

    assert {:ok, _delivery} =
             %ActorEventDelivery{}
             |> ActorEventDelivery.changeset(%{
               actor_event_id: event.id,
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(job.id),
               queue_sequence: event.queue_sequence,
               attempt_no: 1,
               actor_lane_message_id: "skill-disable-turn",
               activation_uid: "skill-disable-activation",
               actor_epoch: 1,
               actor_event_id_fence: event.id,
               revision: 0,
               worker_id: "skill-disable-worker",
               transport_route: route,
               state: "accepted",
               send_outcome: "sent_or_queued",
               error: %{}
             })
             |> Repo.insert()

    assert {:ok, _overlay} = Library.skill_append(agent.uid, "pdf", "Refresh active material.")
    assert_receive {:actor_lane, %{body: {:turn_control, content_control}}}, 2_000
    assert content_control.command == "skill_content_changed"
    assert Torque.decode!(content_control.payload_json) == %{"skill_names" => ["pdf"]}

    response =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-capabilities/skills/pdf", %{
        "enabled" => false
      })
      |> json_response(200)

    assert Enum.find(response["skills"], &(&1["id"] == "pdf"))["effective_enabled"] == false
    assert_receive {:actor_lane, %{body: {:turn_control, control}}}, 2_000
    assert control.command == "skill_disabled"
    assert Torque.decode!(control.payload_json) == %{"skill_names" => ["pdf"]}
    refute_receive {:actor_lane, _envelope}
  end

  defp plugin(capabilities, id), do: Enum.find(capabilities["agent_plugins"], &(&1["id"] == id))
  defp skill(plugin, name), do: Enum.find(plugin["skills"], &(&1["name"] == name))

  defp create_job(agent_uid, suffix, workspace_template_id) do
    BackgroundAgentJobs.create_with_dispatch(%{
      "agent_uid" => agent_uid,
      "owner_session_id" => "parent-session-#{suffix}",
      "source_tool_call_id" => "tool-#{suffix}",
      "workspace_template_id" => workspace_template_id,
      "title" => "Job #{suffix}",
      "task" => "Complete #{suffix}.",
      "reply_route" => %{"binding_name" => "lark"}
    })
  end
end
