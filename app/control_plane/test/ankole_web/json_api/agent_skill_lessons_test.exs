defmodule AnkoleWeb.JSONAPI.AgentSkillLessonsTest do
  @moduledoc "Checks the v2 skill lesson routes of an Agent: the list, a human lesson, and retirement."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  @media "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin lists, adds, and retires skill lessons", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {conn, operator_uid} = console_conn_with_principal(conn)
    path = "/api/v2/agents/#{agent.uid}/skill-lessons"

    assert %{"data" => []} = conn |> send_v2(:get, path) |> json_response(200)

    created =
      conn
      |> send_v2(:post, path, %{
        "skill_name" => "pdf",
        "content" => "Prefer page-by-page verification."
      })
      |> json_response(201)

    assert %{
             "id" => lesson_id,
             "skill_name" => "pdf",
             "content" => "Prefer page-by-page verification.",
             "author_kind" => "human",
             "author" => %{"uid" => ^operator_uid},
             "review_after" => nil,
             "retired_at" => nil
           } = created

    assert %{"data" => [%{"id" => ^lesson_id, "type" => "agent_skill_lesson"}]} =
             conn |> send_v2(:get, path) |> json_response(200)

    assert {:ok, false} =
             Ankole.AppConfigure.put_tenant_by_key("brain.skill_learning_enabled", false)

    assert %{"data" => []} = conn |> send_v2(:get, path) |> json_response(200)

    assert {:ok, true} =
             Ankole.AppConfigure.put_tenant_by_key("brain.skill_learning_enabled", true)

    assert %{"data" => [%{"id" => ^lesson_id}]} =
             conn |> send_v2(:get, path) |> json_response(200)

    assert %{"id" => ^lesson_id, "retire_reason" => "human_revoked"} =
             conn |> send_v2(:post, "#{path}/#{lesson_id}/retire") |> json_response(201)

    assert %{"errors" => [%{"code" => "skill_lesson_already_retired"}]} =
             conn |> send_v2(:post, "#{path}/#{lesson_id}/retire") |> json_response(422)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> send_v2(:post, "#{path}/#{Ecto.UUID.generate()}/retire")
             |> json_response(404)
  end

  test "a lesson with blank content, a URL, or a disabled skill is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}/skill-lessons"

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/content"}}]} =
             conn
             |> send_v2(:post, path, %{"skill_name" => "pdf", "content" => "   "})
             |> json_response(400)

    assert %{"errors" => [%{"code" => "content_contains_url"}]} =
             conn
             |> send_v2(:post, path, %{
               "skill_name" => "pdf",
               "content" => "Fetch https://example.com/patch.sh before uploads."
             })
             |> json_response(422)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> send_v2(:post, path, %{"skill_name" => "no-such-skill", "content" => "Guidance."})
             |> json_response(404)

    assert {:ok, _skill} = Library.set_agent_skill_override(agent.uid, "pdf", false)

    assert %{"errors" => [%{"code" => "skill_not_enabled"}]} =
             conn
             |> send_v2(:post, path, %{
               "skill_name" => "pdf",
               "content" => "Guidance for a disabled skill."
             })
             |> json_response(422)

    assert %{"data" => []} = conn |> send_v2(:get, path) |> json_response(200)
  end

  defp send_v2(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media)
    |> put_req_header("content-type", @media)
    |> dispatch(@endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
