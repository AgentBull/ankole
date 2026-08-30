defmodule AnkoleWeb.IdentityMappingRequestControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ.Grant
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    {:ok, true} = SetupConfig.put_completed(true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "missing bearer token returns 401", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/identity-mapping-requests")

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "bearer-authenticated callers without resource grants are forbidden", %{conn: conn} do
    conn = bearer_conn(conn)
    revoke_console_grants()

    conn = get(conn, ~p"/api/v1/identity-mapping-requests")

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
  end

  test "admin lists, binds, and dismisses pending mapping requests", %{conn: conn} do
    %{principal: target} = human_fixture()

    assert {:ok, bindable} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_console_bind",
               display_name: "Console Bindable"
             })

    assert {:ok, dismissable} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_console_dismiss"
             })

    conn = bearer_conn(conn)

    listed =
      conn
      |> get(~p"/api/v1/identity-mapping-requests")
      |> json_response(200)

    assert Enum.count(listed["identity_mapping_requests"]) == 2

    bound =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/identity-mapping-requests/#{bindable.id}/bind", %{
        "principal_uid" => target.uid
      })
      |> json_response(200)

    assert bound["identity_mapping"]["principal_uid"] == target.uid
    assert bound["identity_mapping"]["external_id"] == "ou_console_bind"

    assert {:ok, resolved} =
             Principals.resolve_platform_subject("lark-main", "ou_console_bind")

    assert resolved.uid == target.uid

    remaining =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/identity-mapping-requests/#{dismissable.id}")
      |> json_response(200)

    assert remaining["identity_mapping_requests"] == []
  end

  test "binding to an agent principal is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_console_refused"
             })

    conn =
      conn
      |> bearer_conn()
      |> post(~p"/api/v1/identity-mapping-requests/#{request.id}/bind", %{
        "principal_uid" => agent.uid
      })

    assert %{"error" => %{"code" => "invalid_principal"}} = json_response(conn, 422)
  end

  test "a malformed mapping request id answers not found in the console envelope", %{conn: conn} do
    %{principal: target} = human_fixture()
    conn = bearer_conn(conn)

    assert %{"error" => %{"code" => "not_found", "message" => message}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/identity-mapping-requests/not-a-uuid/bind", %{
               "principal_uid" => target.uid
             })
             |> json_response(404)

    assert is_binary(message)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> recycle_api()
             |> delete(~p"/api/v1/identity-mapping-requests/not-a-uuid")
             |> json_response(404)
  end

  test "admin maps a provider subject proactively", %{conn: conn} do
    %{principal: target} = human_fixture()

    mapped =
      conn
      |> bearer_conn()
      |> post(~p"/api/v1/identity-mappings", %{
        "principal_uid" => target.uid,
        "provider" => "lark-main",
        "external_id" => "ou_proactive_console"
      })
      |> json_response(200)

    assert mapped["identity_mapping"]["principal_uid"] == target.uid

    assert {:ok, resolved} =
             Principals.resolve_platform_subject("lark-main", "ou_proactive_console")

    assert resolved.uid == target.uid
  end

  test "admin cannot reassign a provider subject", %{conn: conn} do
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()

    conn =
      conn
      |> bearer_conn()
      |> post(~p"/api/v1/identity-mappings", %{
        "principal_uid" => first.uid,
        "provider" => "lark-main",
        "external_id" => "ou_bound_once"
      })

    assert json_response(conn, 200)

    assert %{"error" => %{"code" => "subject_already_bound"}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/identity-mappings", %{
               "principal_uid" => second.uid,
               "provider" => "lark-main",
               "external_id" => "ou_bound_once"
             })
             |> json_response(409)

    assert {:ok, resolved} =
             Principals.resolve_platform_subject("lark-main", "ou_bound_once")

    assert resolved.uid == first.uid
  end

  defp revoke_console_grants do
    Repo.delete_all(from grant in Grant, where: grant.resource_pattern == "**")
  end
end
