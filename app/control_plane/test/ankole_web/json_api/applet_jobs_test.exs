defmodule AnkoleWeb.JSONAPI.AppletJobsTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  alias Ankole.Pod.{Bases, Files, Pages}

  test "a browser manages an Action, its source binding and Run through the declared API", %{
    conn: conn
  } do
    {browser, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Pages.create(actor, %{type: "applet", title: "Browser Action"})
    publish(actor, page)
    path = "/api/v2/pod/pages/#{page.id}"

    assert %{"actions" => ["sync"]} =
             browser |> request(:get, path <> "/job-actions") |> json_response(200)

    created =
      browser
      |> request(:post, path <> "/jobs", %{action_key: "sync", authorization_kind: "service"})
      |> json_response(201)

    job = created["job"]
    assert is_integer(job["id"])
    assert job["page_id"] == page.id
    assert job["action_key"] == "sync"
    assert %{"jobs" => [^job]} = browser |> request(:get, path <> "/jobs") |> json_response(200)

    schedule =
      browser
      |> request(:put, path <> "/jobs/#{job["id"]}/schedules", %{
        name: "business",
        schedule: %{kind: "cron", expression: "*/10 9-11,13-15 * * 1-5"},
        timezone: "Asia/Shanghai",
        payload: %{mode: "intraday"}
      })
      |> json_response(200)

    assert schedule["result"]["owner_job_id"] == job["id"]
    assert schedule["result"]["payload"] == %{"mode" => "intraday"}

    assert %{"result" => %{"name" => "business", "payload" => %{"mode" => "closing"}}} =
             browser
             |> request(:put, path <> "/jobs/#{job["id"]}/schedules", %{
               id: schedule["result"]["id"],
               payload: %{mode: "closing"}
             })
             |> json_response(200)

    browser |> request(:delete, path <> "/jobs/9223372036854775000") |> json_response(404)

    assert %{"result" => [_]} =
             browser
             |> request(:get, path <> "/jobs/#{job["id"]}/schedules")
             |> json_response(200)

    endpoint =
      browser
      |> request(:post, path <> "/jobs/#{job["id"]}/webhooks", %{
        label: "Inbound",
        expires_at: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()
      })
      |> json_response(201)

    refute Map.has_key?(endpoint["result"]["webhook_endpoint"], "token_digest")
    assert is_binary(endpoint["result"]["token"])

    assert endpoint["result"]["callback_path"] ==
             "/webhooks/v1/event-callbacks/" <> endpoint["result"]["token"]

    endpoint_id = endpoint["result"]["webhook_endpoint"]["id"]

    assert %{"result" => %{"status" => "paused"}} =
             browser
             |> request(:post, path <> "/jobs/#{job["id"]}/webhooks/#{endpoint_id}/pause", %{})
             |> json_response(201)

    configured =
      browser
      |> request(:patch, path <> "/jobs/#{job["id"]}", %{config: %{batchSize: 10}})
      |> json_response(200)

    assert configured["job"]["config"] == %{"batchSize" => 10}
    ref = "applet://#{page.id}"

    binding =
      browser
      |> request(:put, "/api/v2/pod/signal-bindings", %{
        config_ref: ref,
        name: "Browser Action subscription",
        automation_job_id: job["id"]
      })
      |> json_response(200)

    assert binding["binding"]["routing_mode"] == "action"
    assert binding["binding"]["automation_job_id"] == job["id"]
    binding_id = binding["binding"]["id"]
    assert {:ok, ^binding_id} = Ecto.UUID.cast(binding_id)

    assert %{"bindings" => [listed_binding]} =
             browser
             |> request(:get, "/api/v2/pod/signal-bindings", %{config_ref: ref})
             |> json_response(200)

    assert listed_binding == binding["binding"]

    {:ok, %{receipts: [receipt]}} =
      Ankole.Signals.emit(
        ref,
        %{
          "id" => "browser-job",
          "type" => "manual",
          "data" => %{"ticket" => "SUPPORT-42"}
        },
        response_mode: :fire_and_forget
      )

    run =
      browser
      |> request(:get, path <> "/runs/#{receipt.automation_job_run_id}")
      |> json_response(200)

    assert run["run"]["status"] == "queued"
    assert run["run"]["automation_job_id"] == job["id"]

    assert %{
             "event" => %{
               "id" => "browser-job",
               "type" => "manual",
               "data" => %{"ticket" => "SUPPORT-42"}
             },
             "started_at" => nil,
             "finished_at" => nil,
             "stdout" => "",
             "stderr" => "",
             "stdout_truncated" => false,
             "stderr_truncated" => false
           } = run["run"]

    assert %{"runs" => [history]} =
             browser |> request(:get, path <> "/jobs/#{job["id"]}/runs") |> json_response(200)

    assert history["id"] == receipt.automation_job_run_id
    assert history == run["run"]

    disabled =
      browser
      |> request(:put, "/api/v2/pod/signal-bindings", %{
        id: binding_id,
        config_ref: ref,
        name: "Browser Action subscription",
        automation_job_id: job["id"],
        enabled: false
      })
      |> json_response(200)

    assert disabled["binding"] == Map.put(binding["binding"], "enabled", false)

    assert %{"bindings" => [disabled_binding]} =
             browser
             |> request(:get, "/api/v2/pod/signal-bindings", %{config_ref: ref})
             |> json_response(200)

    assert disabled_binding == disabled["binding"]

    {:ok, other_page} = Pages.create(actor, %{type: "applet", title: "Other"})

    browser
    |> request(:get, "/api/v2/pod/pages/#{other_page.id}/runs/#{receipt.automation_job_run_id}")
    |> json_response(403)

    browser
    |> request(:get, "/api/v2/pod/pages/#{other_page.id}/jobs/#{job["id"]}/runs")
    |> json_response(403)

    replacement = Ankole.PrincipalsFixtures.human_fixture().principal

    transferred =
      browser
      |> request(:put, path <> "/applet-owner", %{owner_uid: replacement.uid})
      |> json_response(200)

    assert transferred["page"]["owner_uid"] == replacement.uid

    browser |> request(:delete, path <> "/jobs/#{job["id"]}") |> json_response(200)
    assert %{"jobs" => []} = browser |> request(:get, path <> "/jobs") |> json_response(200)

    assert %{"bindings" => []} =
             browser
             |> request(:get, "/api/v2/pod/signal-bindings", %{config_ref: ref})
             |> json_response(200)
  end

  test "a frontend-only Applet lists no Actions", %{conn: conn} do
    {browser, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Pages.create(actor, %{type: "applet", title: "Frontend only"})
    publish(actor, page, [{"src/main.tsx", "source"}, {"dist/index.html", "<html/>"}])

    assert %{"actions" => []} =
             browser
             |> request(:get, "/api/v2/pod/pages/#{page.id}/job-actions")
             |> json_response(200)
  end

  test "the Base API exposes unique keys, upserts and normalized no-op writes", %{conn: conn} do
    {browser, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Pages.create(actor, %{type: "base", title: "Rows"})
    {:ok, table} = Bases.create_table(actor, page.id, %{name: "Contacts"})
    {:ok, schema} = Bases.get_table(actor, table.id)
    key = hd(schema.fields).id
    path = "/api/v2/pod/tables/#{table.id}"

    configured =
      browser
      |> request(:put, path <> "/settings", %{unique_field_ids: [key], emit_changes: true})
      |> json_response(200)

    assert configured["table"]["unique_field_ids"] == [key]
    assert configured["table"]["emit_changes"]
    data = %{upserts: [%{data: %{key => "customer-1"}}]}
    written = browser |> request(:post, path <> "/records", data) |> json_response(201)
    unchanged = browser |> request(:post, path <> "/records", data) |> json_response(201)
    assert unchanged["data_version"] == written["data_version"]
    assert unchanged["records"] == written["records"]
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

  defp publish(
         actor,
         page,
         files \\ [
           {"src/main.tsx", "source"},
           {"dist/index.html", "<html/>"},
           {"server/main.js",
            "export default {actions:{sync:{idempotent:true,handler:async()=>1}}}"}
         ]
       ) do
    manifest =
      for {path, bytes} <- files do
        {:ok, blob} = Ankole.Files.store(bytes)
        source = "publish/#{page.id}/#{path}"

        {:ok, _} =
          Ankole.Files.commit(actor.principal.uid, [
            Map.merge(blob, %{path: source, source: "agent"})
          ])

        %{path: path, object_id: blob.object_id, source_path: source}
      end

    assert {:ok, _} = Files.publish(actor, page.id, 0, manifest)
  end
end
