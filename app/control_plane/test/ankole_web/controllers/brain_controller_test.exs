defmodule AnkoleWeb.BrainControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry, as: SignalEntry
  alias AnkoleWeb.Session, as: WebSession

  setup %{conn: conn} do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    owner = agent_fixture(%{uid: unique_uid("brain-owner")})
    {conn, admin_uid} = bearer_conn(conn)

    {:ok, conn: conn, owner_uid: owner.principal.uid, admin_uid: admin_uid}
  end

  test "OpenAPI exposes every Brain supervision route and bearer auth runs first", %{
    owner_uid: owner_uid
  } do
    spec_conn = get(build_conn(), ~p"/api/v1/openapi.json")
    spec = json_response(spec_conn, 200)
    paths = spec["paths"]
    schemas = spec["components"]["schemas"]

    assert Map.has_key?(paths, "/api/v1/brain/entries")
    assert Map.has_key?(paths, "/api/v1/brain/entries/{id}")
    assert Map.has_key?(paths, "/api/v1/brain/entry-operations")
    assert Map.has_key?(paths, "/api/v1/brain/audit-log")
    assert Map.has_key?(paths, "/api/v1/brain/entries/{id}/audit-log")
    assert Map.has_key?(paths, "/api/v1/brain/sources/{document_id}")
    assert Map.has_key?(paths, "/api/v1/brain/audit-log/restorations")
    assert Map.has_key?(paths, "/api/v1/brain/audit-log/{audit_id}/restorations")
    assert Map.has_key?(paths, "/api/v1/brain/dreaming-runs")

    assert schemas["BrainEntryBlock"]["properties"]["author_kind"]["enum"] ==
             ["human", "agent", "dreaming"]

    assert schemas["BrainAuditLog"]["properties"]["actor_kind"] == %{
             "enum" => ["human", "agent", "dreaming"],
             "nullable" => true,
             "type" => "string"
           }

    refute "actor_kind" in schemas["BrainAuditLog"]["required"]

    conn = get(build_conn(), ~p"/api/v1/brain/entries?owner_uid=#{owner_uid}")
    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "console search and cursors expose every entry and exact audit selections restore atomically",
       %{conn: conn, owner_uid: owner_uid} do
    {conn, alpha_id} = create_console_entry(conn, owner_uid, "Paged Alpha")
    {conn, beta_id} = create_console_entry(conn, owner_uid, "Paged Beta")

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries?owner_uid=#{owner_uid}&query=Paged&limit=1")

    assert %{"entries" => [first], "next_cursor" => cursor} = json_response(conn, 200)
    assert is_binary(cursor)

    conn =
      conn
      |> recycle_bearer()
      |> get(
        ~p"/api/v1/brain/entries?owner_uid=#{owner_uid}&query=Paged&limit=1&cursor=#{cursor}"
      )

    assert %{"entries" => [second], "next_cursor" => nil} = json_response(conn, 200)
    assert MapSet.new([first["id"], second["id"]]) == MapSet.new([alpha_id, beta_id])

    conn =
      conn
      |> recycle_bearer()
      |> get(
        ~p"/api/v1/brain/audit-log?owner_uid=#{owner_uid}&actor=human&action=create_entry&limit=1"
      )

    assert %{"audit_log" => [first_audit], "next_cursor" => audit_cursor} =
             json_response(conn, 200)

    assert is_binary(audit_cursor)

    conn =
      conn
      |> recycle_bearer()
      |> get(
        ~p"/api/v1/brain/audit-log?owner_uid=#{owner_uid}&actor=human&action=create_entry&limit=1&cursor=#{audit_cursor}"
      )

    assert %{"audit_log" => [second_audit]} = json_response(conn, 200)
    refute second_audit["id"] == first_audit["id"]

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/audit-log/restorations?owner_uid=#{owner_uid}", %{
        "audit_ids" => [first_audit["id"]]
      })

    assert %{
             "restoration" => %{
               "restored_count" => 1,
               "batch_restore_id" => batch_restore_id
             }
           } = json_response(conn, 200)

    assert is_binary(batch_restore_id)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{first_audit["entry_id"]}?owner_uid=#{owner_uid}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "human supervisor can manually run the owner's scheduled Stage B path", %{
    conn: conn,
    owner_uid: owner_uid
  } do
    conn = post(conn, ~p"/api/v1/brain/dreaming-runs?owner_uid=#{owner_uid}", %{})

    assert %{
             "run" => %{
               "status" => "no_new_material",
               "material_count" => 0,
               "operation_count" => 0
             }
           } = json_response(conn, 200)
  end

  test "block edits derive store from the block when the HTTP request omits store and entry id",
       %{
         conn: conn,
         owner_uid: owner_uid
       } do
    {conn, entry_id} = create_console_entry(conn, owner_uid, "Block-only routing")

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}", %{
        "operations" => [
          %{
            "operation" => "append_block",
            "entry_id" => entry_id,
            "body" => "Before",
            "expected_entry_lock_version" => 1
          }
        ]
      })

    assert %{
             "results" => [
               %{
                 "block_id" => block_id,
                 "block_lock_version" => block_lock_version
               }
             ]
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}", %{
        "operations" => [
          %{
            "operation" => "edit_block",
            "block_id" => block_id,
            "body" => "After",
            "expected_block_lock_version" => block_lock_version
          }
        ]
      })

    assert %{"results" => [%{"operation" => "edit_block"}]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry_id}?owner_uid=#{owner_uid}")

    assert %{"blocks" => [%{"body" => "After"}]} = json_response(conn, 200)
  end

  test "human console operations use query scope and bearer actor, then expose projection and audit",
       %{
         conn: conn,
         owner_uid: owner_uid,
         admin_uid: admin_uid
       } do
    conn =
      post(conn, ~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}&store=public", %{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Project Alpha",
            "type" => "project",
            "summary" => "Initial summary",
            "aliases" => ["Alpha"],
            "properties" => %{"stage" => "draft"}
          }
        ]
      })

    assert %{"results" => [_], "touched_entry_ids" => [_]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}&store=public", %{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Industry One",
            "type" => "industry"
          }
        ]
      })

    assert %{"results" => [_]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries?owner_uid=#{owner_uid}&type=project&store=public")

    assert %{"entries" => [entry]} = json_response(conn, 200)
    assert entry["owner_uid"] == owner_uid
    assert entry["store_key"] == "public"
    assert entry["name"] == "Project Alpha"

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries?owner_uid=#{owner_uid}")

    assert %{"entries" => entries} = json_response(conn, 200)
    target = Enum.find(entries, &(&1["name"] == "Industry One")) || flunk("target entry missing")

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}", %{
        "operations" => [
          %{
            "operation" => "append_block",
            "entry_id" => entry["id"],
            "body" => "Current status (src:signal-gateway-entry:test)",
            "expected_entry_lock_version" => entry["lock_version"]
          }
        ]
      })

    assert %{"results" => [_]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}?owner_uid=#{owner_uid}")

    assert %{
             "entry" => %{"name" => "Project Alpha"} = opened_entry,
             "blocks" => [
               %{
                 "body" => "Current status (src:signal-gateway-entry:test)",
                 "author_kind" => "human",
                 "author_uid" => ^admin_uid
               }
             ],
             "markdown" => markdown
           } = json_response(conn, 200)

    assert markdown =~ "Project Alpha"

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}", %{
        "operations" => [
          %{
            "operation" => "add_relation",
            "entry_id" => entry["id"],
            "target_entry_id" => target["id"],
            "predicate" => "belongs to",
            "expected_entry_lock_version" => opened_entry["lock_version"]
          }
        ]
      })

    assert %{"results" => [_]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}?owner_uid=#{owner_uid}")

    assert %{
             "relations" => [
               %{
                 "predicate" => "belongs to",
                 "target_entry_id" => target_id,
                 "target_name" => "Industry One"
               }
             ],
             "markdown" => relation_markdown
           } = json_response(conn, 200)

    assert target_id == target["id"]
    assert relation_markdown =~ "Industry One"

    conn =
      conn
      |> recycle_bearer()
      |> get(
        ~p"/api/v1/brain/entries?owner_uid=#{owner_uid}&author=human&updated=2020-01-01T00:00:00Z"
      )

    assert %{"entries" => [%{"id" => entry_id}]} = json_response(conn, 200)
    assert entry_id == entry["id"]

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}/audit-log?owner_uid=#{owner_uid}")

    assert %{"audit_log" => audit_rows} = json_response(conn, 200)
    assert Enum.any?(audit_rows, &(&1["action"] == "create_entry"))

    assert Enum.any?(audit_rows, fn row ->
             row["action"] == "append_block" and row["actor_kind"] == "human" and
               row["actor_uid"] == admin_uid
           end)

    append_audit =
      Enum.find(audit_rows, &(&1["action"] == "append_block")) ||
        flunk("append_block audit row was not returned")

    conn =
      conn
      |> recycle_bearer()
      |> post(
        ~p"/api/v1/brain/audit-log/#{append_audit["id"]}/restorations?owner_uid=#{owner_uid}",
        %{}
      )

    assert %{"restoration" => %{"restored" => "append_block"}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}?owner_uid=#{owner_uid}")

    assert %{
             "entry" => restored_entry,
             "blocks" => [],
             "relations" => [%{"target_name" => "Industry One"}]
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}", %{
        "operations" => [
          %{
            "operation" => "delete_entry",
            "entry_id" => entry["id"],
            "expected_entry_lock_version" => restored_entry["lock_version"]
          }
        ]
      })

    assert %{"results" => [%{"operation" => "delete_entry"}]} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}/audit-log?owner_uid=#{owner_uid}")

    assert %{"audit_log" => deleted_audit_rows} = json_response(conn, 200)

    delete_audit =
      Enum.find(deleted_audit_rows, &(&1["action"] == "delete_entry")) ||
        flunk("delete_entry audit row was not returned")

    conn =
      conn
      |> recycle_bearer()
      |> post(
        ~p"/api/v1/brain/audit-log/#{delete_audit["id"]}/restorations?owner_uid=#{owner_uid}",
        %{}
      )

    assert %{"restoration" => %{"restored" => "delete_entry"}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/entries/#{entry["id"]}?owner_uid=#{owner_uid}")

    assert %{
             "entry" => %{"name" => "Project Alpha"},
             "blocks" => [],
             "relations" => [%{"target_name" => "Industry One"}]
           } = json_response(conn, 200)
  end

  test "operation body cannot choose owner, store, or author", %{
    conn: conn,
    owner_uid: owner_uid
  } do
    other_owner = agent_fixture(%{uid: unique_uid("other-brain-owner")})

    conn =
      post(conn, ~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}&store=public", %{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Spoofed entry",
            "type" => "project",
            "owner_uid" => other_owner.principal.uid,
            "store_key" => "dm:someone-else",
            "author_kind" => "dreaming"
          }
        ]
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "source citations resolve by stable SignalsGateway document id", %{conn: conn} do
    document_id = "signal-gateway-entry:source-test"
    insert_source!(document_id)

    conn = get(conn, ~p"/api/v1/brain/sources/#{document_id}")

    assert %{
             "source" => %{
               "document_id" => ^document_id,
               "text" => "Original source text",
               "author" => %{"display_name" => "Alice"}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/brain/sources/signal-gateway-entry:missing")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp bearer_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("brain-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    access_token =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: human.principal.uid,
        provider_id: "lark-main",
        external_id: "external-1"
      })
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })
      |> json_response(200)
      |> Map.fetch!("access_token")

    bearer =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")

    {bearer, human.principal.uid}
  end

  defp create_console_entry(conn, owner_uid, name) do
    conn =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/brain/entry-operations?owner_uid=#{owner_uid}&store=public", %{
        "operations" => [%{"operation" => "create_entry", "name" => name, "type" => "topic"}]
      })

    assert %{"results" => [%{"entry_id" => entry_id}]} = json_response(conn, 200)
    {conn, entry_id}
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end

  defp insert_source!(document_id) do
    now = DateTime.utc_now(:microsecond)
    channel_id = "lark:chat:brain-source-#{System.unique_integer([:positive])}"

    %Channel{}
    |> Channel.changeset(%{
      id: channel_id,
      kind: :im_group,
      reply_mode: :entry,
      name: "Research",
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()

    %SignalEntry{}
    |> SignalEntry.changeset(%{
      signal_channel_id: channel_id,
      source_entry_id: "provider-message-1",
      text: "Original source text",
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice", "principal_uid" => "alice"},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: now,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: document_id,
      search_text: "Original source text",
      metadata_text: "",
      content_hash: "source-hash",
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
