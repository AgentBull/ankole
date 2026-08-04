defmodule AnkoleWeb.AgentLibrarySkillOverlayControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    assert {:ok, _result} = Library.sync_builtin_skills(force: true)

    :ok
  end

  test "admin reads, replaces, and deletes one agent skill overlay", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/agents/#{agent.uid}/library-skill-overlays")
    assert %{"skill_overlays" => []} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf", %{
        "text" => "Prefer page-by-page verification.",
        "expected_content_hash" => ""
      })

    assert %{
             "skill_overlays" => [
               %{
                 "skill_name" => "pdf",
                 "skill_id" => "pdf",
                 "effective_enabled" => true,
                 "text" => "Prefer page-by-page verification.",
                 "content_hash" => content_hash
               }
             ]
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf", %{
        "text" => "Stale overwrite.",
        "expected_content_hash" => ""
      })

    assert %{"error" => %{"code" => "skill_overlay_conflict"}} = json_response(conn, 409)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf", %{
        "text" => "Consolidated verification guidance.",
        "expected_content_hash" => content_hash
      })

    assert %{"skill_overlays" => [%{"text" => "Consolidated verification guidance."}]} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf")

    assert %{"skill_overlays" => []} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "skill overlay endpoints reject blank text, unknown agents, and disabled skills", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/agents/missing-agent/library-skill-overlays")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf", %{
        "text" => "   ",
        "expected_content_hash" => ""
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    assert {:ok, _skill} = Library.set_agent_skill_override(agent.uid, "pdf", false)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-skill-overlays/pdf", %{
        "text" => "Guidance for a disabled skill.",
        "expected_content_hash" => ""
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp recycle_api(conn) do
    conn
    |> recycle()
    |> put_req_header("authorization", get_req_header(conn, "authorization") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("skill-overlay-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end
end
