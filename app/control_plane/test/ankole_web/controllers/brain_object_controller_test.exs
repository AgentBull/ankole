defmodule AnkoleWeb.BrainObjectControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
    {:ok, false} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), false)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "the object page shows one stored invalid body and the type list is readable", %{
    conn: conn
  } do
    {:ok, _result} = SchemaPacks.install_packs([])
    {conn, principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    invalid_body = """
    {% audience scope="principal:#{principal_uid}" %}
    private
    ~~~markdoc
    {% /audience %}
    ~~~
    tail
    """

    %Object{}
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{
      id: UUIDv7.autogenerate(),
      tenant_id: Repo.tenant_id!(),
      slug: "notes/repair-invalid-markdoc",
      type: "note",
      title: "Repair invalid Markdoc",
      body: invalid_body,
      meta: %{},
      content_hash: "invalid-markdoc-fixture",
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()

    assert %{
             "object" => %{
               "body" => ^invalid_body,
               "content_hash" => "invalid-markdoc-fixture",
               "editable" => true
             }
           } =
             conn
             |> api(:get, ~p"/api/v2/brain/objects/show?slug=notes%2Frepair-invalid-markdoc")
             |> json_response(200)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> recycle_api()
             |> api(:get, ~p"/api/v2/brain/objects/show?slug=notes%2Fmissing")
             |> json_response(404)

    assert %{"types" => types} =
             conn
             |> recycle_api()
             |> api(:get, ~p"/api/v2/brain/object-types")
             |> json_response(200)

    assert "note" in types
    refute "agent-skills" in types
  end

  defp api(conn, method, path) do
    conn
    |> recycle_api()
    |> delete_req_header("content-type")
    |> put_req_header("accept", "application/vnd.api+json")
    |> dispatch(@endpoint, method, path, nil)
  end
end
