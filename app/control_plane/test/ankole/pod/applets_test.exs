defmodule Ankole.Pod.AppletsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Applets, Database, Files, Pages}
  alias Ankole.Files, as: Drive

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    owner = human_fixture().principal.uid
    reader = human_fixture().principal.uid
    %{owner: owner, reader: reader}
  end

  test "unexpected capability failures log their cause and return the bounded public error",
       ctx do
    page = create(ctx.owner)

    context = %{
      "principal" => %{"uid" => ctx.owner},
      "applet" => %{"pageId" => page.id, "revision" => 3},
      "method" => "POST"
    }

    log =
      ExUnit.CaptureLog.capture_log(
        [format: "$metadata $message\n", metadata: [:event, :page_id, :exception, :stacktrace]],
        fn ->
          assert {:error, %{code: "handler_error", status: 500}} =
                   Ankole.Pod.Applets.Capabilities.call(context, [], "file.write", [
                     page.id,
                     %{
                       "name" => "x",
                       "bytes" => %{
                         "__ankole_bytes" => %{"secret" => "raw-argument-must-not-appear"}
                       }
                     }
                   ])
        end
      )

    assert log =~ "pod.applet.capability_failed"
    assert log =~ page.id
    assert log =~ "exception"
    assert log =~ "stacktrace"
    refute log =~ "raw-argument-must-not-appear"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %{code: "invalid_request"}} =
                 Ankole.Pod.Applets.Capabilities.call(context, [], "unknown-operation", [])
      end)

    refute log =~ "capability_failed"
  end

  test "publication inspects the package and replaces source, frontend and backend atomically",
       ctx do
    page = create(ctx.owner)
    good = "export default {'GET /hello': () => ({version: 1})}"
    assert {:ok, %{revision: 1, routes: ["GET /hello"]}} = publish(ctx.owner, page, 0, good)
    {:ok, before} = Files.manifest(ctx.owner, page.id)

    for bad <- [
          "export default {",
          "export default []",
          "export default {'GET /x': 2}",
          "export default {'GET /:a':()=>1,'GET /:b':()=>2}",
          "await AnkoleRuntime.db.query('x',{}); export default {}"
        ] do
      assert {:error, {:invalid_applet_routes, %{reason: reason}}} =
               publish(ctx.owner, page, 1, bad)

      assert is_binary(reason)
      assert {:ok, ^before} = Files.manifest(ctx.owner, page.id)

      assert {:ok, %{"body" => %{"version" => 1}}} =
               call(ctx.owner, page.id, "GET", "/hello", revision: 1)
    end

    assert {:ok, %{revision: 2, routes: []}} = publish(ctx.owner, page, 1, nil)
    assert {:error, :route_not_found} = call(ctx.owner, page.id, "GET", "/hello", revision: 2)
    assert {:error, :not_found} = Files.read(ctx.owner, page.id, "server/main.js")
  end

  test "route matching, caller context, JSON values, errors and per-call state use the published package",
       ctx do
    page = create(ctx.owner)

    source = """
    let count = 0;
    export default {
      'GET /orders/new':()=>({literal:true}),
      'GET /orders/:id':r=>({id:r.params.id,query:r.query,principal:r.principal,applet:r.applet,timezone:r.timezone,count:++count}),
      'POST /body':r=>r.body,
      'DELETE /empty':()=>undefined,
      'POST /invalid':()=>{ throw new AnkoleRuntime.HttpError(409,'business_rule','Cannot change',{current:7}) },
      'GET /crash':()=>{throw new Error('private-debug-message')},
      'GET /cycle':()=>{const a={};a.self=a;return a}
    }
    """

    {:ok, _} = publish(ctx.owner, page, 0, source)

    assert {:ok, %{"status" => 200, "body" => %{"literal" => true}}} =
             call(ctx.owner, page.id, "GET", "/orders/new")

    request = %{
      "method" => "GET",
      "path" => "/orders/a%2Fb",
      "query" => %{"tag" => ["one", "two"], "a[b]" => "flat"}
    }

    for _ <- 1..2 do
      assert {:ok, %{"body" => body}} = Applets.call(ctx.owner, page.id, request)
      assert body["id"] == "a/b"
      assert body["count"] == 1
      assert body["query"] == request["query"]
      assert body["principal"]["uid"] == ctx.owner
      assert body["principal"]["kind"] == "human"
      assert body["applet"] == %{"pageId" => page.id, "revision" => 1}
      assert is_binary(body["timezone"])
    end

    assert {:ok, %{"status" => 405}} = call(ctx.owner, page.id, "POST", "/orders/new")
    assert {:ok, %{"status" => 404}} = call(ctx.owner, page.id, "GET", "/missing")
    assert {:ok, %{"status" => 204} = empty} = call(ctx.owner, page.id, "DELETE", "/empty")
    refute Map.has_key?(empty, "body")

    assert {:ok,
            %{
              "status" => 409,
              "body" => %{"error" => %{"code" => "business_rule", "details" => %{"current" => 7}}}
            }} = call(ctx.owner, page.id, "POST", "/invalid")

    assert {:ok, %{"status" => 500} = human_error} = call(ctx.owner, page.id, "GET", "/crash")
    refute Map.has_key?(human_error, "debug")
    refute Map.has_key?(human_error, "logs")
    agent = agent_fixture().principal.uid
    share(ctx.owner, page.id, agent, "view")

    assert {:ok, %{"status" => 500, "debug" => %{"message" => message}}} =
             call(agent, page.id, "GET", "/crash")

    assert message =~ "private-debug-message"

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "handler_error"}}}} =
             call(ctx.owner, page.id, "GET", "/cycle")

    assert {:ok, %{"body" => [1, true]}} =
             Applets.call(ctx.owner, page.id, %{
               "method" => "POST",
               "path" => "/body",
               "query" => %{},
               "body" => [1, true]
             })

    raw = %{"error" => %{"message" => "ordinary JSON payload"}}

    assert {:ok, %{"status" => 200, "body" => ^raw}} =
             Applets.call(ctx.owner, page.id, request("POST", "/body", raw))
  end

  test "revision and current access are checked before executing any handler", ctx do
    page = create(ctx.owner)
    {:ok, _} = publish(ctx.owner, page, 0, "export default {'GET /':()=>42}")
    assert {:error, :forbidden} = call(ctx.reader, page.id, "GET", "/")

    assert {:error, {:applet_revision_changed, %{revision: 1}}} =
             call(ctx.owner, page.id, "GET", "/", revision: 0)

    {:ok, _} = Pages.delete(ctx.owner, page.id)
    assert {:error, :not_found} = call(ctx.owner, page.id, "GET", "/")
  end

  test "Database capabilities use caller permissions, preserve field conflicts, and prevent GET writes",
       ctx do
    {:ok, db} = Pages.create(ctx.owner, %{type: "database", private_owner_uid: ctx.owner})
    {:ok, table} = Database.create_table(ctx.owner, db.id, %{name: "Orders"})
    {:ok, field} = Database.create_field(ctx.owner, table.id, %{name: "Label", type: "text"})
    page = create(ctx.owner)

    source = """
    export default {
      'GET /schema':()=>AnkoleRuntime.db.schema('#{table.id}'),
      'POST /write':r=>AnkoleRuntime.db.write('#{table.id}',r.body),
      'GET /write':()=>AnkoleRuntime.db.write('#{table.id}',{creates:[{data:{'#{field.id}':'Forbidden'}}]}),
      'POST /query':r=>AnkoleRuntime.db.query('#{table.id}',r.body)
    }
    """

    {:ok, _} = publish(ctx.owner, page, 0, source)
    share(ctx.owner, page.id, ctx.reader, "view")
    assert {:ok, %{"status" => 403}} = call(ctx.reader, page.id, "GET", "/schema")
    share(ctx.owner, db.id, ctx.reader, "view")
    assert {:ok, %{"status" => 200}} = call(ctx.reader, page.id, "GET", "/schema")
    body = %{"creates" => [%{"data" => %{field.id => "First"}}]}

    assert {:ok, %{"status" => 403}} =
             Applets.call(ctx.reader, page.id, request("POST", "/write", body))

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "read_only_route"}}}} =
             call(ctx.owner, page.id, "GET", "/write")

    assert {:ok, %{records: []}} = Database.query(ctx.owner, table.id, %{})

    assert {:ok, %{"body" => %{"records" => [record]}}} =
             Applets.call(ctx.owner, page.id, request("POST", "/write", body))

    assert record["data"][field.id] == "First"

    conflict = %{
      "updates" => [
        %{
          "id" => record["id"],
          "data" => %{field.id => "Stale"},
          "expected_versions" => %{field.id => 0}
        }
      ]
    }

    assert {:ok,
            %{
              "status" => 409,
              "body" => %{"error" => %{"code" => "field_conflict", "details" => details}}
            }} = Applets.call(ctx.owner, page.id, request("POST", "/write", conflict))

    assert details != nil

    assert {:ok, %{"status" => 422}} =
             Applets.call(ctx.owner, page.id, request("POST", "/query", %{"local" => true}))
  end

  test "file capabilities preserve bytes, full paths, document URLs and revision conflicts",
       ctx do
    {:ok, file} = Pages.create(ctx.owner, %{type: "file", private_owner_uid: ctx.owner})
    {:ok, doc} = Pages.create(ctx.owner, %{type: "doc", private_owner_uid: ctx.owner})
    page = create(ctx.owner)

    source = """
    export default {
      'POST /file': async r => {
        const result = await AnkoleRuntime.file.write('#{file.id}', {name:'data.bin',bytes:new Uint8Array([0,255,42]),baseRevision:r.body.revision});
        const read = await AnkoleRuntime.file.read(result.path);
        return {...result,bytes:Array.from(read.bytes),list:await AnkoleRuntime.file.list('#{file.id}')};
      },
      'POST /image':()=>AnkoleRuntime.file.write('#{doc.id}',{name:'image.png',contentType:'image/png',bytes:new Uint8Array([1,2,3])}),
      'GET /write':()=>AnkoleRuntime.file.write('#{file.id}',{name:'bad',bytes:new Uint8Array([1]),baseRevision:1})
    }
    """

    {:ok, _} = publish(ctx.owner, page, 0, source)

    assert {:ok, %{"status" => 200, "body" => result}} =
             Applets.call(ctx.owner, page.id, request("POST", "/file", %{"revision" => 0}))

    assert result["bytes"] == [0, 255, 42]
    assert result["path"] == "pages/#{file.id}/data.bin"
    assert hd(result["list"]["files"])["path"] == result["path"]

    assert {:ok, %{"status" => 409}} =
             Applets.call(ctx.owner, page.id, request("POST", "/file", %{"revision" => 0}))

    assert {:ok, %{"body" => %{"url" => "ankole:asset/" <> _}}} =
             call(ctx.owner, page.id, "POST", "/image")

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "read_only_route"}}}} =
             call(ctx.owner, page.id, "GET", "/write")

    assert {:ok, _, <<0, 255, 42>>} = Files.read(ctx.owner, file.id, "data.bin")
  end

  test "uploaded backend attachments can be saved in a Database record and read with the same bytes",
       ctx do
    {:ok, database} = Pages.create(ctx.owner, %{type: "database", private_owner_uid: ctx.owner})
    {:ok, table} = Database.create_table(ctx.owner, database.id, %{name: "Reports"})

    {:ok, field} =
      Database.create_field(ctx.owner, table.id, %{name: "Files", type: "attachment"})

    page = create(ctx.owner)

    source = """
    export default {'POST /attach':async()=>{
      const file = await AnkoleRuntime.file.write('#{database.id}',{name:'report.txt',contentType:'text/plain',bytes:new Uint8Array([65,66])});
      const record = await AnkoleRuntime.db.write('#{table.id}',{creates:[{data:{'#{field.id}':[{path:file.path,name:'report.txt',mime:file.contentType,size:file.size}]}}]});
      return {file,record};
    }}
    """

    {:ok, _} = publish(ctx.owner, page, 0, source)

    assert {:ok, %{"status" => 200, "body" => %{"file" => file}}} =
             call(ctx.owner, page.id, "POST", "/attach")

    assert {:ok, %{records: [record]}} = Database.query(ctx.owner, table.id, %{})
    assert [%{"path" => path, "size" => 2, "mime" => "text/plain"}] = record["data"][field.id]
    assert file["path"] == path
    {:ok, id, relative} = Files.parse_path(path)
    assert id == database.id
    assert {:ok, _, "AB"} = Files.read(ctx.owner, database.id, relative)
  end

  test "invocations enforce tenant limits and a failed call does not poison later calls", ctx do
    assert {:ok, _} =
             Ankole.AppConfigure.put_tenant_by_key("pod.applet.limits", %{
               "timeout_ms" => 80,
               "heap_mb" => 16
             })

    page = create(ctx.owner)

    {:ok, _} =
      publish(
        ctx.owner,
        page,
        0,
        "export default {'GET /loop':()=>{while(true){}},'GET /ok':()=>true}"
      )

    assert {:ok, %{"status" => 504, "body" => %{"error" => %{"code" => "handler_timeout"}}}} =
             call(ctx.owner, page.id, "GET", "/loop")

    assert {:ok, %{"status" => 200, "body" => true}} = call(ctx.owner, page.id, "GET", "/ok")

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(fn -> call(ctx.owner, page.id, "GET", "/ok") end)
    end
  end

  test "overload returns 503 applet_busy for route invocations and publication inspection", ctx do
    page = create(ctx.owner)
    {:ok, _} = publish(ctx.owner, page, 0, "export default {'GET /ok':()=>true}")

    hold_source = "export default {'POST /hold':()=>AnkoleRuntime.db.query('t',{})}"

    hold_context = %{
      "method" => "POST",
      "path" => "/hold",
      "query" => %{},
      "principal" => %{"uid" => ctx.owner, "kind" => "human"},
      "applet" => %{"pageId" => page.id, "revision" => 1},
      "timezone" => "Asia/Singapore"
    }

    active =
      for _ <- 1..4 do
        {:ok, handle, run_id} =
          Ankole.Kernel.AppletRuntime.start(hold_source, hold_context, timeout_ms: 10_000)

        assert_receive {:applet_runtime, ^run_id, :call, _id, "db.query", _}, 2_000
        {handle, run_id}
      end

    try do
      assert {:ok,
              %{
                "status" => 503,
                "body" => %{
                  "error" => %{
                    "code" => "applet_busy",
                    "message" => "Applet runtime is at capacity",
                    "details" => nil
                  }
                }
              }} = call(ctx.owner, page.id, "GET", "/ok")

      assert {:error, :applet_busy} =
               publish(ctx.owner, page, 1, "export default {'GET /next':()=>1}")
    after
      Enum.each(active, fn {handle, run_id} ->
        Ankole.Kernel.AppletRuntime.cancel(handle)
        assert_receive {:applet_runtime, ^run_id, :done, _}, 2_000
      end)
    end
  end

  defp create(uid),
    do: elem(Pages.create(uid, %{type: "applet", title: "Backend", private_owner_uid: uid}), 1)

  defp call(uid, id, method, path, opts \\ []),
    do: Applets.call(uid, id, %{"method" => method, "path" => path, "query" => %{}}, opts)

  defp request(method, path, body),
    do: %{"method" => method, "path" => path, "query" => %{}, "body" => body}

  defp share(owner, id, reader, role),
    do:
      Ankole.Pod.PagesFixtures.set_sharing(owner, id, %{
        grants: [%{principal_uid: reader, role: role}]
      })

  defp publish(uid, page, revision, server) do
    files = [{"src/main.tsx", "frontend source"}, {"dist/index.html", "frontend"}]
    files = if server, do: files ++ [{"server/main.js", server}], else: files

    manifest =
      Enum.map(files, fn {path, bytes} ->
        {:ok, blob} = Drive.store(bytes)

        {:ok, _} =
          Drive.commit(uid, [
            %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "agent"}
          ])

        %{path: path, sha256: blob.sha256}
      end)

    Files.publish(uid, page.id, revision, manifest)
  end
end
