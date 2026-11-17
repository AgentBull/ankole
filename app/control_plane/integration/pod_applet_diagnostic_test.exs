defmodule AnkoleWeb.PodAppletDiagnosticIntegrationTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod
  @moduletag sandbox: false
  alias Ankole.Pod.{Applets, Bases, Files, Pages}
  alias Ankole.Files, as: Drive
  import Ankole.PrincipalsFixtures

  setup do
    owner = human_fixture().principal.uid
    reader = human_fixture().principal.uid
    actor = actor_fixture(owner)
    {:ok, base} = Pages.create(actor, %{type: "base", private_owner_uid: owner})
    {:ok, table} = Bases.create_table(actor, base.id, %{name: "Orders"})
    {:ok, field} = Bases.create_field(actor, table.id, %{name: "Amount", type: "number"})

    {:ok, _} =
      Bases.write_records(actor, table.id, %{
        creates: [%{id: Ankole.Ecto.UUIDv7.autogenerate(), data: %{field.id => 7}}]
      })

    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner})
    %{owner: owner, actor: actor, reader: reader, page: page, table: table, field: field}
  end

  test "tickets allow real Base reads and GET handlers while every Pod write reports a diagnostic denial",
       ctx do
    manifest =
      publish_files(ctx, [
        {"src/main.tsx", "source"},
        {"dist/index.html", "<head></head>"},
        {"dist/main.js", "export {}"},
        {"server/main.js",
         "export default {'GET /ready':()=>({ready:true}), 'GET /query':ctx=>({query:ctx.query}), 'GET /item/:id':ctx=>({id:ctx.params.id}), 'GET /bad':()=>AnkoleRuntime.base.write('#{ctx.table.id}',{creates:[]})}"}
      ])

    assert {:ok, %{revision: 1}} = Files.publish(ctx.actor, ctx.page.id, 0, manifest)
    assert {:ok, ticket} = Applets.Diagnostics.ticket(ctx.actor, %{id: ctx.page.id})
    prefix = URI.parse(ticket.url).path
    shell_conn = get(ctx.conn, prefix)
    assert html_response(shell_conn, 200) =~ "applet-diagnostic-config"
    refute html_response(shell_conn, 200) =~ "embed_props"
    assert Plug.Conn.get_resp_header(shell_conn, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(shell_conn, "referrer-policy") == ["no-referrer"]
    assert response(get(ctx.conn, prefix <> "/frame/main.js"), 200) == "export {}"

    assert %{"actions" => []} =
             json_response(get(ctx.conn, prefix <> "/api/pages/#{ctx.page.id}/job-actions"), 200)

    assert %{"jobs" => []} =
             json_response(get(ctx.conn, prefix <> "/api/pages/#{ctx.page.id}/jobs"), 200)

    {:ok, other_doc} = Pages.create(ctx.actor, %{type: "doc", private_owner_uid: ctx.owner})

    {:ok, asset_upload} =
      Files.upload(
        ctx.actor,
        other_doc.id,
        "asset",
        nil,
        "chart.txt",
        "chart-bytes",
        "text/plain"
      )

    assert response(
             get(ctx.conn, prefix <> "/api/files/#{other_doc.id}/#{asset_upload.file.path}"),
             200
           ) == "chart-bytes"

    assert response(
             get(ctx.conn, prefix <> "/files/#{other_doc.id}/#{asset_upload.file.path}"),
             200
           ) == "chart-bytes"

    outsider = human_fixture().principal.uid

    {:ok, private_doc} =
      Pages.create(actor_fixture(outsider), %{type: "doc", private_owner_uid: outsider})

    {:ok, secret_upload} =
      Files.upload(
        actor_fixture(outsider),
        private_doc.id,
        "asset",
        nil,
        "secret.txt",
        "secret-bytes",
        "text/plain"
      )

    assert json_response(
             get(ctx.conn, prefix <> "/api/files/#{private_doc.id}/#{secret_upload.file.path}"),
             403
           )

    assert %{"records" => [_]} =
             json_response(
               post_json(ctx.conn, prefix <> "/api/tables/#{ctx.table.id}/query", %{}),
               201
             )

    aggregate = %{metrics: [%{operation: "count", alias: "count"}]}

    assert %{"groups" => [_]} =
             json_response(
               post_json(ctx.conn, prefix <> "/api/tables/#{ctx.table.id}/aggregate", aggregate),
               201
             )

    assert %{"ready" => true} =
             json_response(get(ctx.conn, prefix <> "/api/pages/#{ctx.page.id}/routes/ready"), 200)

    assert %{"query" => %{"tag" => ["first", "second"], "term" => "hello world"}} =
             json_response(
               get(
                 ctx.conn,
                 prefix <>
                   "/api/pages/#{ctx.page.id}/routes/query?tag=first&tag=second&term=hello+world"
               ),
               200
             )

    assert %{"id" => "first/second"} =
             json_response(
               get(ctx.conn, prefix <> "/api/pages/#{ctx.page.id}/routes/item/first%2Fsecond"),
               200
             )

    for path <- ["/api/tables/#{ctx.table.id}/records", "/api/pages/#{ctx.page.id}/routes/ready"] do
      assert %{"error" => %{"code" => "diagnostic_read_only"}} =
               json_response(post_json(ctx.conn, prefix <> path, %{}), 403)
    end

    assert %{"error" => %{"code" => "diagnostic_read_only"}} =
             json_response(get(ctx.conn, prefix <> "/api/pages/#{ctx.page.id}/routes/bad"), 403)
  end

  test "draft tickets require editing and remain pinned to the reviewed UUID; expired tickets are rejected",
       ctx do
    manifest =
      publish_files(ctx, [
        {"src/main.tsx", "source"},
        {"dist/index.html", "<head></head>"},
        {"dist/main.js", "export {}"}
      ])

    assert {:ok, %{revision: 1}} = Files.publish(ctx.actor, ctx.page.id, 0, manifest)

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, ctx.page.id, %{
               grants: [%{principal_uid: ctx.reader, role: "view"}]
             })

    assert {:ok, %{draft: draft}} =
             Files.publish(ctx.actor, ctx.page.id, 1, manifest, nil, draft: true)

    assert {:error, _} =
             Applets.Diagnostics.ticket(actor_fixture(ctx.reader), %{
               id: ctx.page.id,
               draft_id: draft.id
             })

    assert {:ok, live} = Applets.Diagnostics.ticket(actor_fixture(ctx.reader), %{id: ctx.page.id})
    assert html_response(get(ctx.conn, URI.parse(live.url).path), 200)

    assert {:ok, ticket} =
             Applets.Diagnostics.ticket(ctx.actor, %{id: ctx.page.id, draft_id: draft.id})

    prefix = URI.parse(ticket.url).path
    assert response(get(ctx.conn, prefix <> "/frame/main.js"), 200) == "export {}"

    assert {:ok, %{draft: next}} =
             Files.publish(ctx.actor, ctx.page.id, 1, manifest, nil, draft: true)

    refute draft.id == next.id
    assert response(get(ctx.conn, prefix <> "/frame/main.js"), 409) =~ "changed(window)"

    payload = %{
      tenant_id: ctx.tenant.id,
      uid: ctx.owner,
      page_id: ctx.page.id,
      target_ref: 1
    }

    valid =
      Phoenix.Token.encrypt(AnkoleWeb.Endpoint, "applet-diagnostic", payload,
        signed_at: System.system_time(:second)
      )

    assert html_response(get(ctx.conn, "/pod/applet-diagnostic/" <> valid), 200) =~
             "applet-diagnostic-config"

    expired =
      Phoenix.Token.encrypt(AnkoleWeb.Endpoint, "applet-diagnostic", payload,
        signed_at: System.system_time(:second) - 61
      )

    assert json_response(get(ctx.conn, "/pod/applet-diagnostic/" <> expired), 403)
  end

  @tag timeout: 120_000
  @tag skip: System.get_env("ANKOLE_APPLET_DIAGNOSTIC_BROWSER") != "1"
  test "a stateless browser renders the published Applet using real query, aggregate and route adapters",
       ctx do
    assets_config = Application.get_env(:ankole, AnkoleWeb.Assets)
    Application.put_env(:ankole, AnkoleWeb.Assets, dev_server: nil)
    on_exit(fn -> Application.put_env(:ankole, AnkoleWeb.Assets, assets_config) end)
    directory = Path.join(System.tmp_dir!(), "ankole-diagnostic-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    script = Path.expand("../webapps/integration/pod-browser/diagnostic-browser.ts")

    {output, status} =
      System.cmd("bun", [script, "build", directory, ctx.table.id], stderr_to_stdout: true)

    assert status == 0, output
    files = directory |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

    manifest =
      publish_files(
        ctx,
        Enum.map(files, fn path -> {path, File.read!(Path.join([directory, "app", path]))} end)
      )

    assert {:ok, %{revision: 1}} = Files.publish(ctx.actor, ctx.page.id, 0, manifest)

    assert {:ok, ticket} =
             Applets.Diagnostics.ticket(ctx.actor, %{
               id: ctx.page.id,
               embed_props: %{region: "华东"}
             })

    listener =
      start_supervised!(
        {Bandit, plug: AnkoleWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    url = ticket.url |> URI.parse() |> Map.put(:port, port) |> URI.to_string()
    {output, status} = System.cmd("bun", [script, "render", url], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "diagnostic browser passed"
  end

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> post(path, JSON.encode!(%{data: body}))

  defp publish_files(ctx, files) do
    Enum.map(files, fn {path, bytes} ->
      {:ok, blob} = Drive.store(bytes)
      source = "diagnostic/#{ctx.page.id}/#{path}"
      {:ok, _} = Drive.commit(ctx.owner, [Map.merge(blob, %{path: source, source: "agent"})])
      %{path: path, object_id: blob.object_id, source_path: source}
    end)
  end
end
