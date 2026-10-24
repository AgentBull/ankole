defmodule Ankole.Pod.AppletLifecycleIntegrationTest do
  @moduledoc "Real PostgreSQL and HTTP transport lifetimes for isolated Applet invocations."
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.Pod.{Applets, Database, Files, Pages}
  alias Ankole.Files, as: Drive

  defmodule TransportPlug do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      Ankole.Repo.with_tenant(opts[:tenant], fn ->
        # This test isolates disconnect handling. Controller tests cover the authenticated router.
        conn =
          conn
          |> AnkoleWeb.Plugs.AppletRouteBody.call([])
          |> assign(:current_principal_uid, opts[:uid])

        [".internal-apis", "pod", "pages", id, "routes" | _] = conn.path_info

        conn = %{conn | params: %{"id" => id}}
        AnkoleWeb.PodAppletController.call(conn, :post)
      end)
    end
  end

  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal.uid
    reader = Ankole.PrincipalsFixtures.human_fixture().principal.uid
    {:ok, page} = Pages.create(owner, %{type: "database", private_owner_uid: owner})
    {:ok, table} = Database.create_table(owner, page.id, %{name: "Durable"})
    {:ok, field} = Database.create_field(owner, table.id, %{name: "Value", type: "text"})

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        {:ok, tenant} = Ankole.Tenants.get(tenant.id)
        {:ok, _} = Ankole.Tenants.delete(tenant)

        Enum.reduce_while(1..100, :pending, fn _, _ ->
          case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => tenant.id}}) do
            :ok -> {:halt, :ok}
            {:snooze, _} -> {:cont, :pending}
          end
        end)
        |> then(&assert(&1 == :ok))

        case Ankole.AIGateway.ProviderConfigs.delete_provider(provider_id(tenant.id)) do
          {:ok, _} ->
            assert {:ok, _} =
                     Ankole.AIGateway.ProviderConfigs.delete_provider(provider_id(tenant.id))

          {:error, :not_found} ->
            :ok
        end
      end)
    end)

    %{owner: owner, reader: reader, database: page, table: table, field: field}
  end

  test "closing the HTTP client cancels the isolate and keeps an already committed write", ctx do
    applet =
      publish(ctx.owner, """
        export default {'POST /commit':async()=>{
          await AnkoleRuntime.db.write('#{ctx.table.id}', {creates: [{data: {'#{ctx.field.id}':'committed'}}]});
          while(true){}
        }}
      """)

    server =
      start_supervised!(
        {Bandit,
         plug: {TransportPlug, tenant: Repo.tenant_id!(), uid: ctx.owner},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        client,
        "POST /api/v2/pod/pages/#{applet.id}/routes/commit HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nx-ankole-applet-revision: 1\r\n\r\n{}"
      )

    eventually(fn -> assert Repo.get!(Ankole.Pod.DbTable, ctx.table.id).record_count == 1 end)
    refute Task.Supervisor.children(Ankole.Pod.AppletTaskSupervisor) == []
    :ok = :gen_tcp.close(client)
    eventually(fn -> assert Task.Supervisor.children(Ankole.Pod.AppletTaskSupervisor) == [] end)
    assert {:ok, %{records: [record]}} = Database.query(ctx.owner, ctx.table.id, %{})
    assert record["data"][ctx.field.id] == "committed"
  end

  test "a persistent HTTP1 connection keeps pipelined request bytes intact across invocations",
       ctx do
    applet =
      publish(ctx.owner, """
        export default {'POST /echo':r=>{
          if(r.body===1){const until=Date.now()+200;while(Date.now()<until){}}
          return {value:r.body};
        }}
      """)

    server =
      start_supervised!(
        {Bandit,
         plug: {TransportPlug, tenant: Repo.tenant_id!(), uid: ctx.owner},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(client) end)

    request = fn value ->
      body = to_string(value)

      "POST /api/v2/pod/pages/#{applet.id}/routes/echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nx-ankole-applet-revision: 1\r\n\r\n#{body}"
    end

    :ok = :gen_tcp.send(client, request.(1))
    eventually(fn -> refute Task.Supervisor.children(Ankole.Pod.AppletTaskSupervisor) == [] end)
    :ok = :gen_tcp.send(client, request.(2))
    responses = receive_until(client, ["{\"value\":1}", "{\"value\":2}"])
    assert length(:binary.matches(responses, "HTTP/1.1 200")) == 2
    :ok = :gen_tcp.send(client, request.(3))
    assert receive_until(client, ["{\"value\":3}"]) =~ "HTTP/1.1 200"
  end

  defp receive_until(socket, expected, received \\ "") do
    if Enum.all?(expected, &String.contains?(received, &1)) do
      received
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
      receive_until(socket, expected, received <> bytes)
    end
  end

  test "capability authorization is checked again after an awaited call and Applet access revocation",
       ctx do
    applet =
      publish(ctx.owner, """
        export default {'GET /read':async()=>{
          await AnkoleRuntime.db.query('#{ctx.table.id}', {});
          return await AnkoleRuntime.db.schema('#{ctx.table.id}');
        }}
      """)

    for page <- [ctx.database, applet] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
          grants: [%{principal_uid: ctx.reader, role: "view"}]
        })
    end

    test = self()

    lock =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _ ->
            Repo.one!(
              from t in Ankole.Pod.DbTable, where: t.id == ^ctx.table.id, lock: "FOR UPDATE"
            )

            send(test, :locked)

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)
      )

    assert_receive :locked

    invocation =
      Task.async(
        Repo.bind_tenant(fn ->
          Applets.call(ctx.reader, applet.id, %{
            "method" => "GET",
            "path" => "/read",
            "query" => %{}
          })
        end)
      )

    eventually(fn ->
      [[count]] =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%db_tables%' AND query LIKE '%FOR SHARE%'"
        ).rows

      assert count > 0
    end)

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, applet.id, %{grants: []})
    send(lock.pid, :release)
    Task.await(lock)

    assert {:ok, %{"status" => 403, "body" => %{"error" => %{"code" => "forbidden"}}}} =
             Task.await(invocation)

    assert {:ok, _} = Database.get_table(ctx.reader, ctx.table.id)
  end

  test "two callers retry field conflicts without losing inventory deductions or going negative",
       ctx do
    {:ok, stock} =
      Database.create_field(ctx.owner, ctx.table.id, %{name: "Stock", type: "number"})

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.owner, ctx.table.id, %{creates: [%{data: %{stock.id => 5}}]})

    applet =
      publish(ctx.owner, """
        export default {'POST /withdraw':async ({body})=>{
          let retries=0;
          while(true){
            const {records}=await AnkoleRuntime.db.query('#{ctx.table.id}',{ids:['#{record.id}']});
            const row=records[0];
            const remaining=row.data['#{stock.id}']-body.amount;
            if(remaining<0) throw new AnkoleRuntime.HttpError(409,'insufficient_stock');
            try {
              await AnkoleRuntime.db.write('#{ctx.table.id}',{updates:[{id:row.id,data:{'#{stock.id}':remaining},expected_versions:{'#{stock.id}':row.versions['#{stock.id}']}}]});
              return {remaining,retries};
            } catch(error){
              if(error.code!=='field_conflict') throw error;
              retries++;
            }
          }
        }}
      """)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, ctx.database.id, %{
        grants: [%{principal_uid: ctx.reader, role: "edit"}]
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, applet.id, %{
        grants: [%{principal_uid: ctx.reader, role: "view"}]
      })

    test = self()

    lock =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _ ->
            Repo.one!(
              from t in Ankole.Pod.DbTable, where: t.id == ^ctx.table.id, lock: "FOR SHARE"
            )

            send(test, :inventory_readable)

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)
      )

    assert_receive :inventory_readable

    request = %{
      "method" => "POST",
      "path" => "/withdraw",
      "query" => %{},
      "body" => %{"amount" => 2}
    }

    callers =
      for uid <- [ctx.owner, ctx.reader],
          do: Task.async(Repo.bind_tenant(fn -> Applets.call(uid, applet.id, request) end))

    eventually(fn ->
      [[waiting]] =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%db_tables%' AND query LIKE '%FOR UPDATE%'"
        ).rows

      assert waiting >= 2
    end)

    send(lock.pid, :release)
    Task.await(lock)

    results =
      Enum.map(callers, fn task ->
        assert {:ok, %{"status" => 200, "body" => body}} = Task.await(task)
        body
      end)

    assert Enum.sort(Enum.map(results, & &1["remaining"])) == [1, 3]
    assert Enum.sum(Enum.map(results, & &1["retries"])) >= 1
    assert {:ok, %{records: [saved]}} = Database.query(ctx.owner, ctx.table.id, %{})
    assert saved["data"][stock.id] == 1

    assert {:ok, %{"status" => 409, "body" => %{"error" => %{"code" => "insufficient_stock"}}}} =
             Applets.call(ctx.reader, applet.id, request)

    assert {:ok, %{records: [unchanged]}} = Database.query(ctx.owner, ctx.table.id, %{})
    assert unchanged["data"][stock.id] == 1
  end

  test "a started invocation retains its immutable package when a new version publishes", ctx do
    applet = publish(ctx.owner, "export default {'GET /version':()=>1}")

    assert {:ok, task} =
             Applets.start(
               ctx.owner,
               applet.id,
               %{"method" => "GET", "path" => "/version", "query" => %{}},
               revision: 1
             )

    {:ok, _} = publish_existing(ctx.owner, applet, 1, "export default {'GET /version':()=>2}")
    assert {:ok, %{"body" => 1}} = Ankole.Pod.Applets.Invocation.await(task)

    assert {:error, {:applet_revision_changed, %{revision: 2}}} =
             Applets.call(
               ctx.owner,
               applet.id,
               %{"method" => "GET", "path" => "/version", "query" => %{}},
               revision: 1
             )

    assert {:ok, %{"body" => 2}} =
             Applets.call(
               ctx.owner,
               applet.id,
               %{"method" => "GET", "path" => "/version", "query" => %{}},
               revision: 2
             )
  end

  test "file writes retain the Pod upload limit before any durable bytes are stored", ctx do
    applet = publish(ctx.owner, "export default {}")
    {:ok, file} = Pages.create(ctx.owner, %{type: "file", private_owner_uid: ctx.owner})

    context = %{
      "method" => "POST",
      "principal" => %{"uid" => ctx.owner},
      "applet" => %{"pageId" => applet.id}
    }

    bytes = :binary.copy(<<0>>, Ankole.WorkerFiles.max_transfer_bytes() + 1)

    args = [
      file.id,
      %{
        "name" => "too-large.bin",
        "baseRevision" => 0,
        "bytes" => %{"__ankole_bytes" => Base.encode64(bytes)}
      }
    ]

    assert {:error, %{status: 413, code: "file_too_large"}} =
             Ankole.Pod.Applets.Capabilities.call(context, nil, "file.write", args)

    assert {:ok, %{revision: 0, files: []}} = Files.manifest(ctx.owner, file.id)
  end

  test "cancelling an Applet with pending AI closes the actual upstream provider request", ctx do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    test = self()

    provider =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5000)
        {:ok, _bytes} = :gen_tcp.recv(socket, 0, 5000)
        send(test, :provider_started)
        await_peer_close(socket)
      end)

    agent = Ankole.PrincipalsFixtures.agent_fixture().principal.uid
    tenant = Repo.tenant_id!()

    on_exit(fn ->
      Repo.with_tenant(tenant, fn ->
        :ok = Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent)
      end)
    end)

    {:ok, _} =
      Ankole.AIGateway.ProviderConfigs.create_provider(%{
        provider_id: provider_id(Repo.tenant_id!()),
        provider_kind: "openai",
        base_url: "http://127.0.0.1:#{port}/v1",
        credential_pool: %{"entries" => [%{"label" => "Local", "api_key" => "test"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      Ankole.AIAgent.ModelProfiles.put_model_profile(agent, "primary", %{
        provider_id: provider_id(Repo.tenant_id!()),
        model: "gpt-5.5"
      })

    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.applet.ai_agent_uid", agent)

    applet =
      publish(
        ctx.owner,
        "export default {'POST /ai':()=>AnkoleRuntime.ai.generateText({model:'primary',prompt:'Wait'})}"
      )

    {:ok, task} =
      Applets.start(ctx.owner, applet.id, %{"method" => "POST", "path" => "/ai", "query" => %{}})

    assert_receive :provider_started, 5000
    Ankole.Pod.Applets.Invocation.cancel(task)
    assert :closed = Task.await(provider, 5000)
    eventually(fn -> assert Task.Supervisor.children(Ankole.Pod.AppletTaskSupervisor) == [] end)
  end

  defp provider_id(tenant), do: "applet-cancel-" <> tenant

  defp await_peer_close(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, _} -> await_peer_close(socket)
      {:error, :closed} -> :closed
      other -> other
    end
  end

  test "measure fresh isolate startup separately from the complete control-plane invocation",
       ctx do
    source = "let value=0;export default {'GET /':()=>++value}"
    applet = publish(ctx.owner, source)

    native =
      for _ <- 1..100 do
        {micros, {:ok, ["GET /"]}} =
          :timer.tc(fn -> Ankole.Kernel.AppletRuntime.inspect(source) end)

        micros
      end

    invocation =
      for _ <- 1..100 do
        {micros, {:ok, %{"status" => 200, "body" => 1}}} =
          :timer.tc(fn ->
            Applets.call(ctx.owner, applet.id, %{"method" => "GET", "path" => "/", "query" => %{}})
          end)

        micros
      end

    IO.puts(
      "APPLET_STARTUP_BENCHMARK " <>
        Torque.encode!(%{
          samples: 100,
          unit: "milliseconds",
          isolate_and_module: timings(native),
          control_plane_invocation: timings(invocation)
        })
    )
  end

  defp timings(samples) do
    sorted = Enum.sort(samples)

    %{
      first: hd(samples) / 1000,
      median: Enum.at(sorted, 49) / 1000,
      p95: Enum.at(sorted, 94) / 1000
    }
  end

  defp eventually(fun, remaining \\ 100)

  defp eventually(fun, remaining) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if remaining <= 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(20)
      eventually(fun, remaining - 1)
  end

  defp publish(uid, source) do
    {:ok, page} = Pages.create(uid, %{type: "applet", private_owner_uid: uid})
    {:ok, _} = publish_existing(uid, page, 0, source)
    page
  end

  defp publish_existing(uid, page, revision, source) do
    manifest =
      Enum.map(
        [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
        fn {path, bytes} ->
          {:ok, blob} = Drive.store(bytes)

          {:ok, _} =
            Drive.commit(uid, [
              %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "pod"}
            ])

          %{path: path, sha256: blob.sha256}
        end
      )

    Files.publish(uid, page.id, revision, manifest)
  end
end
