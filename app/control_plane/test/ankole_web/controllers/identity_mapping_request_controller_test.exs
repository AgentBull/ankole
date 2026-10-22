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
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "missing browser session returns 401", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/identity-mapping-requests")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "session-authenticated callers without resource grants are forbidden", %{conn: conn} do
    conn = console_conn(conn)
    revoke_console_grants()

    conn = get(conn, ~p"/api/v1/identity-mapping-requests")

    assert json_response(conn, 403) ==
             %{"error" => %{"code" => "forbidden", "message" => "access denied", "details" => []}}
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

    conn = console_conn(conn)

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
      |> console_conn()
      |> post(~p"/api/v1/identity-mapping-requests/#{request.id}/bind", %{
        "principal_uid" => agent.uid
      })

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "invalid_principal",
               "message" => "identities bind to human principals only"
             }
           }
  end

  test "a malformed mapping request id answers not found in the console envelope", %{conn: conn} do
    %{principal: target} = human_fixture()
    conn = console_conn(conn)

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
      |> console_conn()
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

  test "an unhandled domain error does not expose the internal reason", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> post(~p"/api/v1/identity-mappings", %{
        "principal_uid" => "   ",
        "provider" => "lark-main",
        "external_id" => "ou_unhandled_console"
      })

    assert json_response(conn, 500) == %{
             "error" => %{
               "code" => "internal_error",
               "message" => "the request failed for an unexpected reason; check the server log"
             }
           }

    refute conn.resp_body =~ "invalid_uid"
  end

  test "admin cannot reassign a provider subject", %{conn: conn} do
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()

    conn =
      conn
      |> console_conn()
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
