defmodule AnkoleWeb.DirectoryAccessControllerTest do
  use AnkoleWeb.ConnCase, async: false
  alias Ankole.IdentityProviders.DirectoryAccess
  alias Ankole.Principals

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "a directory review exposes missing people, requires an exact snapshot, and records the reviewer",
       %{conn: conn} do
    {conn, admin_uid} = bearer_conn_with_principal(conn)

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
      |> get(~p"/api/v1/identity-providers/lark/directory")
      |> json_response(200)

    assert response["snapshot"]["missing_uids"] == [person.principal.uid]

    body = %{
      snapshot_fingerprint: state.snapshot_fingerprint,
      reason: "Verified provider scope",
      confirm_removals: false
    }

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/identity-providers/lark/directory-reviews", body)
           |> json_response(409)

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/identity-providers/lark/directory-reviews", %{
             body
             | confirm_removals: true
           })
           |> json_response(200)
           |> get_in(["snapshot", "reviewed_by"]) == admin_uid

    assert {:ok, %{status: :disabled}} = Principals.get_principal(person.principal.uid)
  end

  test "event review cannot cross providers and keeps the review reason", %{conn: conn} do
    conn = bearer_conn(conn)

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
           |> post(
             ~p"/api/v1/identity-providers/other/directory-events/#{event.id}/reviews",
             body
           )
           |> json_response(404)

    response =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/identity-providers/lark/directory-events/#{event.id}/reviews", body)
      |> json_response(200)

    assert [%{"status" => "dismissed", "review_reason" => "Verified reassigned provider ID"}] =
             response["events"]
  end
end
