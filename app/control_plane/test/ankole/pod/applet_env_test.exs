defmodule Ankole.Pod.AppletEnvTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  import Ankole.PrincipalsFixtures

  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{AppletEnv, Applets.Env, Files, Pages}

  require Ash.Query

  test "4-layer merge precedence (Site -> Pod -> applet.env.json -> Applet) and reserved key stripping" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner.uid})

    assert {:ok, _} =
             WorkerEnv.console_put_global("TIER_SITE_ONLY", %{
               "value" => "from-site",
               "secret" => false
             })

    assert {:ok, _} =
             WorkerEnv.console_put_global("TIER_POD_WINS", %{
               "value" => "site-v",
               "secret" => false
             })

    assert {:ok, _} =
             WorkerEnv.console_put_global("TIER_DEFAULT_WINS", %{
               "value" => "site-v",
               "secret" => false
             })

    assert {:ok, _} =
             WorkerEnv.console_put_global("TIER_APPLET_WINS", %{
               "value" => "site-v",
               "secret" => true
             })

    assert {:ok, _} =
             WorkerEnv.console_put_tenant("TIER_POD_WINS", %{
               "value" => "from-pod",
               "secret" => false
             })

    assert {:ok, _} =
             WorkerEnv.console_put_tenant("TIER_DEFAULT_WINS", %{
               "value" => "pod-v",
               "secret" => false
             })

    assert {:ok, _} =
             WorkerEnv.console_put_tenant("TIER_APPLET_WINS", %{
               "value" => "pod-v",
               "secret" => true
             })

    env_json =
      Ankole.JSON.encode!(%{
        "LEGACY_FLAT" => "flat-default",
        "TIER_DEFAULT_WINS" => %{
          "default" => "from-default",
          "description" => "Structured default"
        },
        "TIER_APPLET_WINS" => %{"default" => "default-v", "required" => true, "secret" => true},
        "REQUIRED_MISSING" => %{
          "required" => true,
          "secret" => true,
          "description" => "Must be set"
        }
      })

    publish_env_manifest(owner.uid, actor, page.id, 0, env_json)

    assert {:ok, %{missing_required_count: 1}} = Env.status(actor, page.id)

    assert {:ok, %{"status" => 200, "body" => %{"bootVal" => "default-v"}}} =
             Ankole.Pod.Applets.call(actor, page.id, %{
               "method" => "GET",
               "path" => "/env",
               "query" => %{}
             })

    assert {:ok, _} =
             Env.put(actor, page.id, "TIER_APPLET_WINS", %{
               "value" => "from-applet-secret",
               "secret" => true,
               "description" => "Applet secret override"
             })

    # Updating Applet env without re-publishing rotates sha256/poolKey and spawns a fresh isolate!
    assert {:ok,
            %{"status" => 200, "body" => %{"bootVal" => "from-applet-secret", "env" => live_env}}} =
             Ankole.Pod.Applets.call(actor, page.id, %{
               "method" => "GET",
               "path" => "/env",
               "query" => %{}
             })

    assert live_env["TIER_SITE_ONLY"] == "from-site"
    assert live_env["TIER_POD_WINS"] == "from-pod"
    assert live_env["TIER_DEFAULT_WINS"] == "from-default"
    assert live_env["TIER_APPLET_WINS"] == "from-applet-secret"
    assert live_env["LEGACY_FLAT"] == "flat-default"
    refute Map.has_key?(live_env, "REQUIRED_MISSING")

    # Reserved and non-POSIX names are rejected across both flat and structured applet.env.json formats
    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"ANKOLE_SECRET":"nope"}))

    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"PATH":"nope"}))

    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"API-KEY":"nope"}))

    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"DATABASE_URL": {"default": "nope"}}))

    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"BLANK_DEFAULT": "   "}))

    assert {:error, :invalid_manifest} =
             Env.parse_manifest(~s({"BLANK_SPEC_DEFAULT": {"default": ""}}))

    # Oversized undeclared WorkerEnv values do not brick unrelated Applets
    oversized_inherited = String.duplicate("x", 60_000)

    assert {:ok, _} =
             WorkerEnv.console_put_tenant("UNDECLARED_HUGE_BLOB", %{
               "value" => oversized_inherited,
               "secret" => false
             })

    assert {:ok, merged_under_budget} =
             Env.effective_env_from_manifest(page.id, %{
               defaults: %{"DECLARED_VAR" => String.duplicate("y", 10_000)},
               specs: %{
                 "DECLARED_VAR" => %{
                   default: String.duplicate("y", 10_000),
                   required: false,
                   secret: false,
                   description: nil
                 }
               }
             })

    assert Map.has_key?(merged_under_budget, "DECLARED_VAR")
    assert Map.has_key?(merged_under_budget, "TIER_APPLET_WINS")
    refute Map.has_key?(merged_under_budget, "UNDECLARED_HUGE_BLOB")
    assert {:ok, _} = WorkerEnv.console_delete_tenant("UNDECLARED_HUGE_BLOB")

    assert {:error, :invalid_manifest} =
             publish_env_manifest_raw(owner.uid, actor, page.id, 1, ~s({"ANKOLE_SECRET":"nope"}))

    assert {:error, {:reserved_worker_env_name, "ANKOLE_TOKEN"}} =
             Env.put(actor, page.id, "ANKOLE_TOKEN", %{"value" => "nope", "secret" => true})
  end

  test "Pod JSON:API enforces Applet and Space environment variable permissions and secret decryption boundaries",
       %{conn: conn} do
    {owner_conn, owner_uid} = console_conn_with_principal(conn)
    owner_actor = actor_fixture(owner_uid)

    editor = human_fixture().principal
    viewer = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner_uid}).principal

    editor_conn = browser_conn_for_uid(conn, editor.uid)
    viewer_conn = browser_conn_for_uid(conn, viewer.uid)

    {:ok, page} = Pages.create(owner_actor, %{type: "applet", private_owner_uid: owner_uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner_uid, page.id, %{
        grants: [
          %{principal_uid: editor.uid, role: "edit"},
          %{principal_uid: viewer.uid, role: "view"},
          %{principal_uid: agent.uid, role: "manage"}
        ]
      })

    {:ok, _} =
      WorkerEnv.console_put_global("SITE_SHARED_SECRET", %{
        "value" => "top-site-secret",
        "secret" => true
      })

    page_path = "/api/v2/pod/pages/#{page.id}"

    assert %{
             "has_backend" => false,
             "revision" => 0,
             "routes" => [],
             "actions" => []
           } =
             viewer_conn
             |> request(:get, page_path <> "/functions")
             |> json_response(200)

    publish_env_manifest(
      owner_uid,
      owner_actor,
      page.id,
      0,
      Ankole.JSON.encode!(%{
        "STRIPE_KEY" => %{"required" => true, "secret" => true, "description" => "Stripe API key"},
        "PUBLIC_BASE_URL" => %{"default" => "https://api.example.com", "secret" => false}
      })
    )

    # 1. Viewer: allowed /envs/status, denied /envs list/put/delete/decrypt
    assert %{"missing_required_count" => 1} =
             viewer_conn |> request(:get, page_path <> "/envs/status") |> json_response(200)

    viewer_conn |> request(:get, page_path <> "/envs") |> json_response(403)

    viewer_conn
    |> request(:put, page_path <> "/envs/STRIPE_KEY", %{value: "sk_live_1", secret: true})
    |> json_response(403)

    # 2. Editor (node_edit without node_manage): can_decrypt is false, can put & reset, DENIED decrypt!
    editor_list = editor_conn |> request(:get, page_path <> "/envs") |> json_response(200)
    assert editor_list["can_decrypt"] == false

    put_resp =
      editor_conn
      |> request(:put, page_path <> "/envs/STRIPE_KEY", %{
        value: "sk_live_applet_secret",
        secret: true,
        description: "Configured by editor"
      })
      |> json_response(200)

    assert put_resp["env"]["name"] == "STRIPE_KEY"
    assert put_resp["env"]["source"] == "applet"
    assert put_resp["env"]["secret"] == true
    assert put_resp["env"]["present"] == true
    assert is_nil(put_resp["env"]["value"])

    assert %{"missing_required_count" => 0} =
             viewer_conn |> request(:get, page_path <> "/envs/status") |> json_response(200)

    editor_conn
    |> request(:post, page_path <> "/envs/STRIPE_KEY/decryptions", %{})
    |> json_response(403)

    # Editor cannot downgrade an existing stored secret to plaintext without supplying a new value
    editor_conn
    |> request(:put, page_path <> "/envs/STRIPE_KEY", %{secret: false})
    |> json_response(422)

    assert %{"env" => %{"secret" => true, "description" => "Updated note"}} =
             editor_conn
             |> request(:put, page_path <> "/envs/STRIPE_KEY", %{
               secret: true,
               description: "Updated note"
             })
             |> json_response(200)

    # Viewer can inspect published backend functions (routes + actions) on the Applet
    assert %{
             "has_backend" => true,
             "revision" => 1,
             "routes" => [%{"method" => "GET", "path" => "/env"}],
             "actions" => [
               %{
                 "key" => "sync_env",
                 "concurrency" => "serial_fifo",
                 "idempotent" => true,
                 "max_slices" => 25
               }
             ]
           } =
             viewer_conn
             |> request(:get, page_path <> "/functions")
             |> json_response(200)

    # 3. Owner (Human with node_manage): can_decrypt is true and can decrypt Applet-owned secret,
    #    while Agent with node_manage and inherited Site/Pod secrets cannot be decrypted here!
    owner_list = owner_conn |> request(:get, page_path <> "/envs") |> json_response(200)
    assert owner_list["can_decrypt"] == true

    assert %{"decrypted_value" => %{"value" => "sk_live_applet_secret"}} =
             owner_conn
             |> request(:post, page_path <> "/envs/STRIPE_KEY/decryptions", %{})
             |> json_response(201)

    assert {:error, :forbidden} = Env.decrypt(actor_fixture(agent), page.id, "STRIPE_KEY")

    owner_conn
    |> request(:post, page_path <> "/envs/SITE_SHARED_SECRET/decryptions", %{})
    |> json_response(403)

    owner_conn
    |> request(:post, page_path <> "/envs/NONEXISTENT_VAR/decryptions", %{})
    |> json_response(404)

    # Editor can override default and reset back to inherited default
    assert %{
             "env" => %{
               "source" => "applet",
               "inherited_source" => "default",
               "value" => "https://staging.example.com"
             }
           } =
             editor_conn
             |> request(:put, page_path <> "/envs/PUBLIC_BASE_URL", %{
               value: "https://staging.example.com",
               secret: false
             })
             |> json_response(200)

    assert %{"env" => %{"source" => "default", "value" => "https://api.example.com"}} =
             editor_conn
             |> request(:delete, page_path <> "/envs/PUBLIC_BASE_URL")
             |> json_response(200)

    # 4. Pod Admin (/api/v2/pod/admin/worker-envs): owner (admin) can CRUD & decrypt tenant secret,
    #    cannot decrypt Site global secret, and non-admin member is denied!
    editor_conn |> request(:get, "/api/v2/pod/admin/worker-envs") |> json_response(403)

    assert %{"worker_env" => %{"name" => "POD_API_KEY", "source" => "tenant", "secret" => true}} =
             owner_conn
             |> request(:put, "/api/v2/pod/admin/worker-envs/POD_API_KEY", %{
               value: "pod-secret-val",
               secret: true
             })
             |> api_response(200)

    assert %{"decrypted_value" => %{"value" => "pod-secret-val"}} =
             owner_conn
             |> request(:post, "/api/v2/pod/admin/worker-envs/POD_API_KEY/decryptions", %{})
             |> api_response(201)

    owner_conn
    |> request(:post, "/api/v2/pod/admin/worker-envs/SITE_SHARED_SECRET/decryptions", %{})
    |> json_response(403)

    owner_conn
    |> request(:post, "/api/v2/pod/admin/worker-envs/NONEXISTENT_VAR/decryptions", %{})
    |> json_response(404)

    # Pod put_worker_env rejects downgrading a stored secret to plaintext without a new value
    owner_conn
    |> request(:put, "/api/v2/pod/admin/worker-envs/POD_API_KEY", %{secret: false})
    |> json_response(422)

    # Blank/whitespace values are rejected even when secret: true
    owner_conn
    |> request(:put, "/api/v2/pod/admin/worker-envs/POD_BLANK_SECRET", %{
      value: "   ",
      secret: true
    })
    |> json_response(422)

    # 5. Permanent Page purge cleans up pod_applet_envs rows
    assert {:ok, _} = Pages.delete(owner_actor, page.id)
    assert {:ok, _} = Pages.purge(owner_actor, page.id)
    assert :ok = Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => page.id}})

    assert [] ==
             AppletEnv
             |> Ash.Query.filter(page_id == ^page.id)
             |> Ankole.Ash.read!()
  end

  defp publish_env_manifest(uid, actor, page_id, revision, env_json) do
    assert {:ok, _} = publish_env_manifest_raw(uid, actor, page_id, revision, env_json)
  end

  defp publish_env_manifest_raw(uid, actor, page_id, revision, env_json) do
    files = %{
      "src/main.tsx" => "export default null",
      "dist/index.html" => "<div/>",
      "server/main.js" => """
      const bootVal = process.env.TIER_APPLET_WINS;
      export default {
        routes: {
          'GET /env': () => ({ bootVal, env: process.env })
        },
        actions: {
          sync_env: {
            concurrency: 'serial_fifo',
            idempotent: true,
            maxSlices: 25,
            handler: () => ({ ok: true })
          }
        }
      }
      """,
      "applet.env.json" => env_json
    }

    manifest =
      for {path, content} <- files do
        {:ok, stored} = Drive.store(content)
        source_path = "env-test/#{System.unique_integer([:positive])}/#{path}"

        {:ok, _} =
          Drive.commit(uid, [Map.merge(stored, %{path: source_path, source: "agent"})])

        %{path: path, object_id: stored.object_id, source_path: source_path}
      end

    Files.publish(actor, page_id, revision, manifest)
  end

  defp api_response(conn, status) do
    body = json_response(conn, status)
    get_in(body, ["meta", "result"]) || body
  end

  defp request(conn, method, path, data \\ %{}) do
    conn =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    if method == :get,
      do: get(conn, path, data),
      else: dispatch(conn, @endpoint, method, path, Ankole.JSON.encode!(%{data: data}))
  end

  defp browser_conn_for_uid(conn, uid) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AnkoleWeb.Session.put_tenant_session(%{
      principal_uid: uid,
      provider_id: "lark-main",
      external_id: "ext-" <> uid
    })
    |> with_console_csrf()
    |> get(~p"/api/v2/browser/session")
    |> recycle_api()
  end
end
