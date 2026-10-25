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
                   Ankole.Pod.Applets.Capabilities.call(
                     context,
                     Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
                     "file.write",
                     [
                       page.id,
                       %{
                         "name" => "x",
                         "bytes" => %{
                           "__ankole_bytes" => %{"secret" => "raw-argument-must-not-appear"}
                         }
                       }
                     ]
                   )
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
                 Ankole.Pod.Applets.Capabilities.call(
                   context,
                   Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
                   "unknown-operation",
                   []
                 )
      end)

    refute log =~ "capability_failed"
  end

  test "publication inspects the package and replaces source, frontend and backend atomically",
       ctx do
    page = create(ctx.owner)
    good = "export default {'GET /hello': () => ({version: 1})}"
    assert {:ok, %{revision: 1, routes: ["GET /hello"]}} = publish(ctx.owner, page, 0, good)
    {:ok, before} = Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    for bad <- [
          "export default {",
          "export default []",
          "export default {'GET /x': 2}",
          "export default {'GET /:a':()=>1,'GET /:b':()=>2}",
          "await AnkoleRuntime.db.query('x',{}); export default {}",
          "try { await AnkoleRuntime.db.query('x',{}) } catch {} export default {}"
        ] do
      assert {:error, {:invalid_applet_routes, %{reason: reason}}} =
               publish(ctx.owner, page, 1, bad)

      assert is_binary(reason)

      assert {:ok, ^before} =
               Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

      assert {:ok, %{"body" => %{"version" => 1}}} =
               call(ctx.owner, page.id, "GET", "/hello", revision: 1)
    end

    assert {:ok, %{revision: 2, routes: []}} = publish(ctx.owner, page, 1, nil)
    assert {:error, :route_not_found} = call(ctx.owner, page.id, "GET", "/hello", revision: 2)

    assert {:error, :not_found} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "server/main.js"
             )
  end

  test "route matching, caller context, JSON values and warm module state use the published package",
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

    for count <- 1..2 do
      assert {:ok, %{"body" => body}} =
               Applets.call(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, request)

      assert body["id"] == "a/b"
      assert body["count"] == count
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
             Applets.call(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, %{
               "method" => "POST",
               "path" => "/body",
               "query" => %{},
               "body" => [1, true]
             })

    raw = %{"error" => %{"message" => "ordinary JSON payload"}}

    assert {:ok, %{"status" => 200, "body" => ^raw}} =
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/body", raw)
             )
  end

  test "revision and current access are checked before executing any handler", ctx do
    page = create(ctx.owner)
    {:ok, _} = publish(ctx.owner, page, 0, "export default {'GET /':()=>42}")
    assert {:error, :forbidden} = call(ctx.reader, page.id, "GET", "/")

    assert {:error, {:applet_revision_changed, %{revision: 1}}} =
             call(ctx.owner, page.id, "GET", "/", revision: 0)

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
    assert {:error, :not_found} = call(ctx.owner, page.id, "GET", "/")
  end

  test "Database capabilities use caller permissions, preserve field conflicts, and prevent GET writes",
       ctx do
    {:ok, db} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "database",
        private_owner_uid: ctx.owner
      })

    {:ok, table} =
      Database.create_table(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), db.id, %{
        name: "Orders"
      })

    {:ok, field} =
      Database.create_field(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), table.id, %{
        name: "Label",
        type: "text"
      })

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
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               request("POST", "/write", body)
             )

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "read_only_route"}}}} =
             call(ctx.owner, page.id, "GET", "/write")

    assert {:ok, %{records: []}} =
             Database.query(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), table.id, %{})

    assert {:ok, %{"body" => %{"records" => [record]}}} =
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/write", body)
             )

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
            }} =
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/write", conflict)
             )

    assert details != nil

    assert {:ok, %{"status" => 422}} =
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/query", %{"local" => true})
             )
  end

  test "file capabilities preserve bytes, full paths, document URLs and revision conflicts",
       ctx do
    {:ok, file} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "file",
        private_owner_uid: ctx.owner
      })

    {:ok, doc} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "doc",
        private_owner_uid: ctx.owner
      })

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
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/file", %{"revision" => 0})
             )

    assert result["bytes"] == [0, 255, 42]
    assert result["name"] == "data.bin"
    assert result["mime"] == "application/octet-stream"
    assert result["path"] == "pages/#{file.id}/data.bin"
    assert hd(result["list"]["files"])["path"] == result["path"]

    assert {:ok, %{"status" => 409}} =
             Applets.call(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               request("POST", "/file", %{"revision" => 0})
             )

    assert {:ok, %{"body" => %{"url" => "ankole:asset/" <> _}}} =
             call(ctx.owner, page.id, "POST", "/image")

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "read_only_route"}}}} =
             call(ctx.owner, page.id, "GET", "/write")

    assert {:ok, _, <<0, 255, 42>>} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), file.id, "data.bin")
  end

  test "Applet viewers submit through writable targets and save attachments as themselves",
       ctx do
    owner = actor_fixture(ctx.owner)
    contributor = actor_fixture(ctx.reader)

    {:ok, database} = Pages.create(owner, %{type: "database", private_owner_uid: ctx.owner})
    {:ok, table} = Database.create_table(owner, database.id, %{name: "Evaluations"})
    {:ok, field} = Database.create_field(owner, table.id, %{name: "Resume", type: "attachment"})
    page = create(ctx.owner)

    source = """
    export default {
      'POST /record':()=>AnkoleRuntime.db.write('#{table.id}',{creates:[{data:{}}]}),
      'POST /file':()=>AnkoleRuntime.file.write('#{database.id}',{name:'resume.txt',bytes:new Uint8Array([65])}),
      'POST /submit':async r=>{
        const file = await AnkoleRuntime.file.write('#{database.id}',{name:r.body.name,contentType:'text/plain',bytes:new Uint8Array(r.body.bytes)});
        const read = await AnkoleRuntime.file.read(file.path);
        const record = await AnkoleRuntime.db.write('#{table.id}',{creates:[{data:{'#{field.id}':[file]}}]});
        return {file,record,isBytes:read.bytes instanceof Uint8Array,bytes:Array.from(read.bytes),byteLength:read.bytes.byteLength};
      }
    }
    """

    assert {:ok, _} = publish(ctx.owner, page, 0, source)
    share(ctx.owner, page.id, ctx.reader, "view")
    share(ctx.owner, database.id, ctx.reader, "view")

    for path <- ["/record", "/file"] do
      assert {:ok, %{"status" => 403}} = call(ctx.reader, page.id, "POST", path)
    end

    assert {:ok, %{records: []}} = Database.query(contributor, table.id, %{})
    assert {:ok, %{files: []}} = Files.manifest(contributor, database.id)

    share(ctx.owner, database.id, ctx.reader, "contribute")

    for {name, bytes} <- [{"resume.txt", [65, 66]}, {"empty.txt", []}] do
      assert {:ok, %{"status" => 200, "body" => result}} =
               Applets.call(
                 contributor,
                 page.id,
                 request("POST", "/submit", %{"name" => name, "bytes" => bytes})
               )

      assert result["isBytes"]
      assert result["bytes"] == bytes
      assert result["byteLength"] == length(bytes)
      assert [record] = result["record"]["records"]

      assert record["created_by"] ==
               "ankole:#{Repo.tenant_id!()}:principal/#{ctx.reader}"

      assert [%{"path" => path, "size" => size, "mime" => "text/plain"}] =
               record["data"][field.id]

      assert size == length(bytes)
      assert path == result["file"]["path"]
      assert result["file"]["name"] == name
      assert result["file"]["mime"] == "text/plain"
      assert {:ok, database_id, relative} = Files.parse_path(path)
      assert database_id == database.id
      assert {:ok, _, contents} = Files.read(contributor, database.id, relative)
      assert contents == :erlang.list_to_binary(bytes)
    end

    for {applet_role, database_role} <- [{"view", "view"}, {"edit", "view"}] do
      share(ctx.owner, page.id, ctx.reader, applet_role)
      share(ctx.owner, database.id, ctx.reader, database_role)

      for path <- ["/record", "/file"] do
        assert {:ok, %{"status" => 403}} = call(ctx.reader, page.id, "POST", path)
      end
    end

    assert {:ok, %{records: records}} = Database.query(contributor, table.id, %{})
    assert length(records) == 2
    assert {:ok, %{files: files}} = Files.manifest(contributor, database.id)
    assert length(files) == 2
  end

  test "publication supplies the package environment during module initialization", ctx do
    page = create(ctx.owner)
    source = "const hook = new URL(process.env.HOOK); export default {'GET /hook':()=>hook.href}"

    assert {:ok, _} =
             publish(ctx.owner, page, 0, source, [
               {"applet.env.json", Torque.encode!(%{"HOOK" => "https://example.com/hook"})}
             ])

    assert {:ok, %{"status" => 200, "body" => "https://example.com/hook"}} =
             call(ctx.owner, page.id, "GET", "/hook")
  end

  test "code cache identity includes environment values with one cross-language key order", ctx do
    page = create(ctx.owner)
    source = "export default {'GET /env':()=>({value:process.env.Z})}"

    env = %{
      "Z" => "quoted \"value\"\n中文",
      "a" => "lower",
      "_KEY" => "underscore",
      "\uE000" => "bmp",
      "😀" => "astral"
    }

    assert {:ok, _} =
             publish(ctx.owner, page, 0, source, [{"applet.env.json", Torque.encode!(env)}])

    assert {:ok, %{"status" => 200, "body" => %{"value" => value}}} =
             call(ctx.owner, page.id, "GET", "/env")

    assert value == env["Z"]
    next = Map.put(env, "Z", "changed")

    assert {:ok, _} =
             publish(ctx.owner, page, 1, source, [{"applet.env.json", Torque.encode!(next)}])

    assert {:ok, %{"status" => 200, "body" => %{"value" => "changed"}}} =
             call(ctx.owner, page.id, "GET", "/env")
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

    active = Ankole.FunctionRuntimeHelpers.saturate()

    try do
      assert {:ok,
              %{
                "status" => 503,
                "body" => %{
                  "error" => %{
                    "code" => "applet_busy",
                    "message" => "Applet invocation failed",
                    "details" => nil
                  }
                }
              }} = call(ctx.owner, page.id, "GET", "/ok")

      assert {:error, :applet_busy} =
               publish(ctx.owner, page, 1, "export default {'GET /next':()=>1}")
    after
      Ankole.FunctionRuntimeHelpers.release(active)
    end
  end

  defp create(uid),
    do:
      elem(
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
          type: "applet",
          title: "Backend",
          private_owner_uid: uid
        }),
        1
      )

  defp call(uid, id, method, path, opts \\ []),
    do:
      Applets.call(
        Ankole.PrincipalsFixtures.actor_fixture(uid),
        id,
        %{"method" => method, "path" => path, "query" => %{}},
        opts
      )

  defp request(method, path, body),
    do: %{"method" => method, "path" => path, "query" => %{}, "body" => body}

  defp share(owner, id, reader, role),
    do:
      Ankole.Pod.PagesFixtures.set_sharing(owner, id, %{
        grants: [%{principal_uid: reader, role: role}]
      })

  defp publish(uid, page, revision, server, extra_files \\ []) do
    files = [{"src/main.tsx", "frontend source"}, {"dist/index.html", "frontend"}]
    files = if server, do: files ++ [{"server/main.js", server}], else: files

    manifest =
      Enum.map(files ++ extra_files, fn {path, bytes} ->
        {:ok, blob} = Drive.store(bytes)

        {:ok, _} =
          Drive.commit(uid, [
            %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "agent"}
          ])

        %{path: path, sha256: blob.sha256}
      end)

    Files.publish(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, revision, manifest)
  end
end
