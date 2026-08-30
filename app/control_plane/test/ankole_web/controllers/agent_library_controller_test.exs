defmodule AnkoleWeb.AgentLibraryControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads and independently replaces MISSION, SOUL, and DESIGN documents", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/agents/#{agent.uid}/library-documents")

    assert %{
             "library_documents" => %{
               "mission" => %{
                 "kind" => "mission",
                 "content" => original_mission,
                 "content_hash" => original_mission_hash
               },
               "soul" => %{
                 "kind" => "soul",
                 "content" => original_soul,
                 "content_hash" => original_soul_hash
               },
               "design" => %{
                 "kind" => "design",
                 "content" => original_design,
                 "content_hash" => original_design_hash
               }
             }
           } = json_response(conn, 200)

    assert original_mission != ""
    assert original_soul != ""
    assert original_design != ""

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/mission", %{
        "content" => "Own the Console research workflow.",
        "expected_content_hash" => original_mission_hash
      })

    assert %{
             "library_document" => %{
               "kind" => "mission",
               "content" => "Own the Console research workflow.",
               "content_hash" => updated_mission_hash
             }
           } = json_response(conn, 200)

    refute updated_mission_hash == original_mission_hash

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/mission", %{
        "content" => "Stale overwrite",
        "expected_content_hash" => original_mission_hash
      })

    assert %{"error" => %{"code" => "agent_library_document_conflict"}} =
             json_response(conn, 409)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/soul", %{
        "content" => "",
        "expected_content_hash" => original_soul_hash
      })

    assert %{"library_document" => %{"kind" => "soul", "content" => ""}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/design", %{
        "content" => "Use cobalt accents and generous whitespace.",
        "expected_content_hash" => original_design_hash
      })

    assert %{
             "library_document" => %{
               "kind" => "design",
               "content" => "Use cobalt accents and generous whitespace."
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/library-documents")

    assert %{
             "library_documents" => %{
               "mission" => %{"content" => "Own the Console research workflow."},
               "soul" => %{"content" => ""},
               "design" => %{"content" => "Use cobalt accents and generous whitespace."}
             }
           } = json_response(conn, 200)
  end

  test "Agent library document endpoints reject invalid and missing resources", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/agents/missing-agent/library-documents")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/setting", %{
        "content" => "invalid",
        "expected_content_hash" => "hash"
      })

    assert %{"error" => _error} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/library-documents/mission", %{
        "content" => "missing hash"
      })

    assert %{"error" => _error} = json_response(conn, 422)
  end
end
