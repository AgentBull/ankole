defmodule AnkoleWeb.JSONAPI.DirectoryAccessOperationsTest do
  use AnkoleWeb.ConnCase, async: false
  alias Ankole.IdentityProviders.DirectoryAccess
  alias Ankole.Principals

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    :ok
  end

  test "a directory review exposes missing people, requires an exact snapshot, and records the reviewer",
       %{conn: conn} do
    {conn, admin_uid} = console_conn_with_principal(conn)
    admin_ref = %{"tenant_id" => Ankole.Repo.tenant_id!(), "uid" => admin_uid}

    {:ok, person} =
      Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark", %{"user_id" => "employee"})

    {:ok, ticket} = DirectoryAccess.begin_sync("lark")

    {:ok, state} =
      DirectoryAccess.finish_sync(ticket, "scope", [],
        admission_scope: "contact",
        maximum_removal_percent: 20
      )

    response =
      conn
      |> recycle_api()
      |> v2_get(~p"/api/v2/identity-providers/lark/directory")
      |> json_response(200)

    assert response["snapshot"]["missing_uids"] == [person.principal.uid]

    body = %{
      snapshot_fingerprint: state.snapshot_fingerprint,
      reason: "Verified provider scope",
      confirm_removals: false
    }

    assert conn
           |> recycle_api()
           |> v2_post(~p"/api/v2/identity-providers/lark/directory-reviews", body)
           |> json_response(409)

    assert conn
           |> recycle_api()
           |> v2_post(~p"/api/v2/identity-providers/lark/directory-reviews", %{
             body
             | confirm_removals: true
           })
           |> json_response(201)
           |> get_in(["snapshot", "reviewed_by"]) == admin_ref

    assert {:ok, %{status: :disabled}} = Principals.get_principal(person.principal.uid)
  end

  test "event review cannot cross providers and keeps the review reason", %{conn: conn} do
    conn = console_conn(conn)

    {:ok, event} =
      DirectoryAccess.receive_event("lark", %{
        event_id: "unresolved",
        event_type: "contact.user.deleted_v3",
        external_ids: ["missing"],
        reason: "departure",
        provider_time: DateTime.utc_now()
      })

    body = %{action: "dismiss", reason: "Verified reassigned provider ID"}

    assert conn
           |> recycle_api()
           |> v2_post(
             ~p"/api/v2/identity-providers/other/directory-events/#{event.id}/reviews",
             body
           )
           |> json_response(404)

    response =
      conn
      |> recycle_api()
      |> v2_post(~p"/api/v2/identity-providers/lark/directory-events/#{event.id}/reviews", body)
      |> json_response(201)

    assert [%{"status" => "dismissed", "review_reason" => "Verified reassigned provider ID"}] =
             response["events"]
  end

  defp v2_get(conn, path), do: get(json_api(conn), path)
  defp v2_post(conn, path, body), do: post(json_api(conn), path, %{data: body})

  defp json_api(conn) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end
end
