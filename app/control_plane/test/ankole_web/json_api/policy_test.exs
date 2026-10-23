defmodule AnkoleWeb.JSONAPI.PolicyTest do
  @moduledoc "Checks the AuthZ rules, the tenant, and the refusals of a JSON:API router."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias JSONAPIPolicyFixture.{Note, Router}
  alias Ecto.Adapters.SQL

  setup %{tenant: tenant} do
    SQL.query!(
      Repo,
      "CREATE TEMP TABLE json_api_policy_notes (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, body text NOT NULL) ON COMMIT DROP"
    )

    human = human_fixture(%{uid: unique_uid("json-api-policy")})
    {:ok, _root} = first_site_admin_fixture(human.principal.uid)
    {:ok, note} = Ankole.Ash.create(Note, :create, %{body: "tenant A"})

    other = Ankole.DataCase.create_tenant()

    {:ok, _other_note} =
      Repo.with_tenant(other.id, fn -> Ankole.Ash.create(Note, :create, %{body: "tenant B"}) end)

    %{uid: human.principal.uid, note: note, tenant: tenant}
  end

  defp request(uid, method, path, body \\ nil) do
    method
    |> Plug.Test.conn(path, body && Jason.encode!(body))
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> assign(:current_principal_uid, uid)
    |> Router.call(Router.init([]))
  end

  defp notes, do: Ankole.Ash.read!(Note) |> Enum.map(& &1.body) |> Enum.sort()

  test "a route with a rule runs its action in the tenant of the Repo context", %{
    uid: uid,
    note: note
  } do
    response = request(uid, :get, "/notes")

    assert response.status == 200

    assert %{"data" => [%{"id" => id, "attributes" => %{"body" => "tenant A"}}]} =
             Jason.decode!(response.resp_body)

    assert id == note.id

    response = request(uid, :get, "/notes/#{note.id}")
    assert %{"data" => %{"id" => ^id}} = Jason.decode!(response.resp_body)
  end

  test "a request without a tenant context fails closed", %{uid: uid} do
    Repo.put_tenant_id(nil)
    response = request(uid, :get, "/notes")

    assert response.status in 400..499
    assert %{"errors" => [_ | _]} = Jason.decode!(response.resp_body)
    refute Map.has_key?(Jason.decode!(response.resp_body), "data")
  end

  test "a route without a rule is refused before its action runs", %{uid: uid} do
    response =
      request(uid, :post, "/notes", %{
        data: %{type: "json_api_policy_note", attributes: %{body: "unauthorized"}}
      })

    assert_forbidden(response)
    assert notes() == ["tenant A"]
  end

  test "a route whose AuthZ check fails is refused before its action runs", %{
    uid: uid,
    note: note
  } do
    response =
      request(uid, :patch, "/notes/#{note.id}", %{
        data: %{type: "json_api_policy_note", id: note.id, attributes: %{body: "changed"}}
      })

    assert_forbidden(response)
    assert notes() == ["tenant A"]
  end

  test "a request without an authenticated Principal is refused" do
    response = request(nil, :get, "/notes")

    assert_forbidden(response)
  end

  test "the OpenAPI document and unknown paths need no rule", %{uid: uid} do
    assert request(uid, :get, "/openapi.json").status == 200
    assert request(uid, :get, "/no-such-route").status == 404
  end

  defp assert_forbidden(response) do
    assert response.status == 403
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/vnd.api+json"

    assert %{"errors" => [%{"status" => "403", "code" => "forbidden"}]} =
             Jason.decode!(response.resp_body)
  end
end
