defmodule AnkoleWeb.AgentLibraryControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "Console returns the real Pod source links for the Agent contracts", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = conn |> console_conn() |> api(:get, ~p"/api/v2/agents/#{agent.uid}/library-documents")
    assert %{"library_documents" => documents} = json_response(conn, 200)
    assert Enum.sort(Map.keys(documents)) == ["agents", "design"]

    for kind <- ["agents", "design"] do
      assert documents[kind]["content"] != ""
      assert [id] = documents[kind]["page_ids"]
      assert [url] = documents[kind]["page_urls"]
      assert String.ends_with?(url, "/pages/" <> Ankole.Kernel.uuid_shorten(id))
    end
  end

  test "contract source lookup rejects a missing Agent", %{conn: conn} do
    conn = conn |> console_conn() |> api(:get, ~p"/api/v2/agents/missing-agent/library-documents")
    assert json_response(conn, 404)
  end

  defp api(conn, method, path) do
    conn
    |> recycle_api()
    |> delete_req_header("content-type")
    |> put_req_header("accept", "application/vnd.api+json")
    |> dispatch(@endpoint, method, path, nil)
  end
end
