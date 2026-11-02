defmodule AnkoleWeb.BrainObjectControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    {:ok, false} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), false)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "the Console points to the canonical Pod page without a second body editor", %{conn: conn} do
    {:ok, _} = SchemaPacks.install_packs([])
    {conn, _uid} = console_conn_with_principal(conn)

    {:ok, page} =
      Ankole.Brain.create_object(
        %{
          slug: "notes/canonical",
          type: "note",
          title: "Canonical page",
          body: "Current knowledge."
        },
        :system
      )

    response =
      conn |> api(:get, ~p"/api/v2/brain/objects/show?slug=#{page.id}") |> json_response(200)

    assert response["object"]["page_id"] == page.id
    assert response["object"]["title"] == "Canonical page"

    assert String.ends_with?(
             response["object"]["pod_url"],
             AnkoleWeb.PodURL.page_path(page.id, page.title)
           )

    refute Map.has_key?(response["object"], "body")
    refute Map.has_key?(response["object"], "editable")

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> api(:get, ~p"/api/v2/brain/objects/show?slug=notes%2Fmissing")
             |> json_response(404)

    assert %{"types" => types} =
             conn |> api(:get, ~p"/api/v2/brain/object-types") |> json_response(200)

    assert "note" in types
  end

  defp api(conn, method, path) do
    conn
    |> recycle_api()
    |> delete_req_header("content-type")
    |> put_req_header("accept", "application/vnd.api+json")
    |> dispatch(@endpoint, method, path, nil)
  end
end
