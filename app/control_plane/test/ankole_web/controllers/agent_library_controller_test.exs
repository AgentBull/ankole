defmodule AnkoleWeb.AgentLibraryControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads and independently replaces MISSION, SOUL, and DESIGN documents", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn = api(conn, :get, ~p"/api/v2/agents/#{agent.uid}/library-documents")

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
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/mission", %{
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
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/mission", %{
        "content" => "Stale overwrite",
        "expected_content_hash" => original_mission_hash
      })

    assert %{"errors" => [%{"detail" => "Agent library document changed since it was loaded"}]} =
             json_response(conn, 409)

    conn =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/soul", %{
        "content" => "",
        "expected_content_hash" => original_soul_hash
      })

    assert %{"library_document" => %{"kind" => "soul", "content" => ""}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/design", %{
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
      |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-documents")

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
    conn = console_conn(conn)

    conn = api(conn, :get, ~p"/api/v2/agents/missing-agent/library-documents")
    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)

    conn =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/setting", %{
        "content" => "invalid",
        "expected_content_hash" => "hash"
      })

    assert %{"errors" => [_error | _]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/mission", %{
        "content" => "missing hash"
      })

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/expected_content_hash"}} | _]} =
             json_response(conn, 400)
  end

  test "a rejected edit cannot change documents in this tenant or another tenant", %{conn: conn} do
    {conn, principal_uid} = console_conn_with_principal(conn)
    %{principal: agent} = agent_fixture()
    {:ok, original} = Ankole.AIAgent.Library.list_agent_documents(agent.uid)
    Ankole.Repo.delete_all(Ankole.AuthZ.Grant)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: principal_uid,
        resource_pattern: "agent:#{agent.uid}:library",
        action: "read",
        condition: "true",
        metadata: %{}
      })

    assert %{"library_documents" => _} =
             conn
             |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-documents")
             |> json_response(200)

    assert %{"errors" => [%{"detail" => "access denied"}]} =
             conn
             |> api(:put, ~p"/api/v2/agents/#{agent.uid}/library-documents/mission", %{
               content: "Unauthorized replacement",
               expected_content_hash: original["mission"]["content_hash"]
             })
             |> json_response(403)

    assert {:ok, ^original} = Ankole.AIAgent.Library.list_agent_documents(agent.uid)

    other = Ankole.DataCase.create_tenant()

    foreign =
      Ankole.Repo.with_tenant(other.id, fn ->
        %{principal: foreign} = agent_fixture()
        foreign
      end)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: principal_uid,
        resource_pattern: "agent:#{foreign.uid}:library",
        action: "read",
        condition: "true",
        metadata: %{}
      })

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> api(:get, ~p"/api/v2/agents/#{foreign.uid}/library-documents")
             |> json_response(404)
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
