defmodule Ankole.AutomationJobs.AppletExecutionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2, publish_applet_fixture: 3]
  require Ash.Query
  alias Ankole.{AutomationJobs, Signals}
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.State
  alias Ankole.FunctionRuntime.{EndpointPool, HTTP}
  alias Ankole.Pod.Pages

  defmodule BusyRoutes do
    import Plug.Conn
    def init(endpoint), do: endpoint

    def call(conn, endpoint) do
      case {conn.method, conn.request_path} do
        {"POST", "/v1/applet/inspect"} ->
          {:ok, bytes, conn} = read_body(conn)

          {:ok, status, body} =
            HTTP.at(endpoint, :post, conn.request_path, Torque.decode!(bytes), 5000)

          send_resp(conn, status, body)

        {"DELETE", _} ->
          send_resp(conn, 204, "")

        _ ->
          send_resp(conn, 503, "runtime_busy")
      end
    end
  end

  setup do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet"})
    %{actor: actor, page: page}
  end

  test "a nested call's 503 after a committed write is terminal, including replay of its wake",
       ctx do
    publish_applet_fixture(ctx, """
    export default {actions:{work:{idempotent:false,handler:async ctx=>{
      const count = await ctx.state.get('count') || 0;
      await ctx.state.set('count', count + 1);
      return AnkoleRuntime.admin.signals.call({actionKey:'helper'});
    }},helper:{idempotent:true,handler:()=>true}}}
    """)

    job = job(ctx)
    run = enqueue(ctx, "first")
    busy_routes()
    assert :ok = execute(run.id)
    assert %{status: :failed, error: "applet_busy"} = AutomationJobs.get_run_record(run.id)
    assert :ok = execute(run.id)
    assert state(job.id, "count") == 1
  end

  test "busy package inspection waits without failing or stranding a queued Run", ctx do
    publish_applet_fixture(
      ctx,
      "export default {actions:{work:{idempotent:false,handler:()=>true}}}"
    )

    job(ctx)
    run = enqueue(ctx, "busy")
    active = Ankole.FunctionRuntimeHelpers.saturate()

    try do
      assert {:snooze, delay} = execute(run.id)
      assert delay > 0
      assert %{status: :queued, attempts: 0} = AutomationJobs.get_run_record(run.id)
    after
      Ankole.FunctionRuntimeHelpers.release(active)
    end

    assert :ok = execute(run.id)

    assert %{status: :succeeded, attempts: 1, result: true} =
             AutomationJobs.get_run_record(run.id)
  end

  test "action capacity waits preserve the coalescing head and execution retry budget", ctx do
    publish_applet_fixture(ctx, """
    export default {actions:{work:{idempotent:false,concurrency:'serial_coalesce',handler:()=>true}}}
    """)

    job(ctx)
    head = enqueue(ctx, "capacity-head")
    active = Ankole.FunctionRuntimeHelpers.saturate(:action)

    try do
      for attempt <- 1..7 do
        assert {:snooze, 10} = execute(head.id, 0, attempt)

        assert %{status: :queued, attempts: ^attempt, attempts_in_slice: 0, attempt_id: nil} =
                 AutomationJobs.get_run_record(head.id)
      end

      tail = enqueue(ctx, "capacity-tail")
      assert tail.id != head.id
      assert enqueue(ctx, "capacity-tail-new").id == tail.id
      assert {:snooze, 10} = execute(head.id, 0, 8)
      assert AutomationJobs.get_run_record(tail.id).attempts == 0
      assert :ok = execute(tail.id)
      assert AutomationJobs.get_run_record(tail.id).status == :queued
    after
      Ankole.FunctionRuntimeHelpers.release(active)
    end

    assert Ankole.Eventually.eventually(fn -> execute(head.id) == :ok end)

    finished = AutomationJobs.get_run_record(head.id)

    assert finished.status == :succeeded and finished.attempts >= 9 and
             finished.attempts_in_slice == 1
  end

  test "continuation waits for handler completion and hands off the same Run with progress",
       ctx do
    publish_applet_fixture(ctx, """
    export default {actions:{work:{idempotent:true,handler:async ctx=>{
      if(ctx.run.sliceCount) return ctx.run.progress;
      const next=await ctx.continueSlice({progress:{page:2},delaySeconds:60});
      await ctx.state.set('ready',true);
      while(!await ctx.state.get('release')) await new Promise(resolve=>setTimeout(resolve,10));
      return next;
    }}}}
    """)

    job = job(ctx)
    run = enqueue(ctx, "slice")
    execution = Task.async(Repo.bind_tenant(fn -> execute(run.id) end))
    assert Ankole.Eventually.eventually(fn -> state(job.id, "ready") == true end)
    current = AutomationJobs.get_run_record(run.id)
    assert current.status == :running and current.slice_count == 0

    refute_enqueued(
      worker: ExecuteRun,
      args: %{"automation_job_run_id" => run.id, "expected_slice_count" => 1}
    )

    assert {:ok, _} =
             AutomationJobs.applet_state(
               %{
                 "job" => %{"id" => job.id},
                 "run" => %{"id" => run.id, "attemptId" => current.attempt_id}
               },
               "set",
               ["default", "release", true]
             )

    assert :ok = Task.await(execution, 10_000)

    assert %{status: :queued, slice_count: 1, progress: %{"page" => 2}} =
             AutomationJobs.get_run_record(run.id)

    [wake] =
      all_enqueued(
        worker: ExecuteRun,
        args: %{"automation_job_run_id" => run.id, "expected_slice_count" => 1}
      )

    assert DateTime.diff(wake.scheduled_at, DateTime.utc_now()) >= 55
    assert :ok = execute(run.id, 1)
    assert %{status: :succeeded, result: %{"page" => 2}} = AutomationJobs.get_run_record(run.id)
  end

  test "errors after requesting continuation never commit the next slice", ctx do
    for {ending, error, revision} <- [
          {"throw Error('after continuation')", "handler_error", 0},
          {"return 'x'.repeat(1024*1024+1)", "handler_output_limit", 1},
          {"return await ctx.continueSlice({progress: []})", ":invalid_request", 2}
        ] do
      publish_applet_fixture(
        ctx,
        """
        export default {actions:{work:{idempotent:true,handler:async ctx=>{
          await ctx.continueSlice({progress:{page:2}}); #{ending};
        }}}}
        """,
        revision
      )

      job = job(ctx)

      {:ok, %{automation_job_run: run}} =
        Repo.transact_top_level(fn ->
          AutomationJobs.enqueue_locked_in_tx(AutomationJobs.lock_job_in_tx(job.id), %{}, [])
        end)

      assert :ok = execute(run.id)

      assert %{status: :failed, slice_count: 0, error: ^error} =
               AutomationJobs.get_run_record(run.id)

      refute_enqueued(
        worker: ExecuteRun,
        args: %{"automation_job_run_id" => run.id, "expected_slice_count" => 1}
      )
    end
  end

  test "admin child calls preserve the original caller and cannot continue the parent Run", ctx do
    publish_applet_fixture(ctx, """
    export default {actions:{work:{handler:async()=>{
      let normal; try {await AnkoleRuntime.signals.call({actionKey:'helper'})} catch(e){normal=e.code}
      return {normal,child:await AnkoleRuntime.admin.signals.call({actionKey:'helper'})};
    }},helper:{handler:async ctx=>{
      let ordinary, continuation;
      try {await AnkoleRuntime.file.list(ctx.applet.pageId)} catch(e){ordinary=e.code}
      try {await ctx.continueSlice()} catch(e){continuation=e.code}
      await AnkoleRuntime.admin.file.list(ctx.applet.pageId);
      return {principal:ctx.principal,ordinary,continuation};
    }}}}
    """)

    job(ctx)
    run = enqueue(ctx, "nested-service")
    assert :ok = execute(run.id)

    assert %{
             status: :succeeded,
             result: %{
               "normal" => "user_authority_unavailable",
               "child" => %{
                 "principal" => nil,
                 "ordinary" => "user_authority_unavailable",
                 "continuation" => "action_attempt_required"
               }
             }
           } = AutomationJobs.get_run_record(run.id)

    caller = actor_fixture(human_fixture().principal.uid)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        grants: [%{principal_uid: caller.principal.uid, role: "contribute"}]
      })

    {:ok, personal} =
      AutomationJobs.create_applet_job(caller, ctx.page.id, "work", %{authorization_kind: "human"})

    {:ok, %{automation_job_run: personal_run}} =
      Repo.transact_top_level(fn ->
        AutomationJobs.enqueue_locked_in_tx(AutomationJobs.lock_job_in_tx(personal.id), %{}, [])
      end)

    assert :ok = execute(personal_run.id)
    result = AutomationJobs.get_run_record(personal_run.id)
    assert result.status == :succeeded
    assert result.result["child"]["principal"]["uid"] == caller.principal.uid
    refute Map.has_key?(result.result["child"], "ordinary")
  end

  test "a lost transport recovers only an idempotent admitted attempt", ctx do
    for {idempotent, revision} <- [{true, 0}, {false, 1}] do
      publish_applet_fixture(
        ctx,
        """
        export default {actions:{work:{idempotent:#{idempotent},handler:async ctx=>{
          await ctx.state.set('started', true);
          await new Promise(resolve=>setTimeout(resolve, 10000));
          return true;
        }}}}
        """,
        revision
      )

      job = job(ctx)

      {:ok, %{automation_job_run: run}} =
        Repo.transact(fn ->
          locked = AutomationJobs.lock_job_in_tx(job.id)
          AutomationJobs.enqueue_locked_in_tx(locked, %{}, [])
        end)

      clients = Task.Supervisor.children(Ankole.FunctionRuntime.Tasks)
      execution = Task.async(Repo.bind_tenant(fn -> execute(run.id) end))

      assert Ankole.Eventually.eventually(fn -> state(job.id, "started") == true end)

      [client] = Task.Supervisor.children(Ankole.FunctionRuntime.Tasks) -- clients
      {:links, links} = Process.info(client, :links)
      [socket] = Enum.filter(links, &is_port/1)
      assert :ok = :gen_tcp.close(socket)
      # Exercise the real write failure when a capability reply meets a lost socket.
      Ankole.FunctionRuntime.AppletClient.reply(client, 1, {:ok, true})
      assert :ok = Task.await(execution, 10_000)
      saved = AutomationJobs.get_run_record(run.id)
      assert saved.status == if(idempotent, do: :queued, else: :failed)
      assert saved.error =~ "execution outcome unknown"
      assert saved.attempt_idempotent == idempotent
    end
  end

  test "publishing parallel policy wakes serial tails and preserves an existing slice delay",
       ctx do
    source =
      "export default {actions:{work:{idempotent:true,concurrency:'serial_fifo',handler:()=>true}}}"

    publish_applet_fixture(ctx, source)
    job = job(ctx)
    head = enqueue(ctx, "head")
    {:ok, attempt} = AutomationJobs.start_applet_attempt(head.id, 0)
    tail = enqueue(ctx, "tail")
    refute_enqueued(worker: ExecuteRun, args: %{"automation_job_run_id" => tail.id})

    assert {:ok, _} =
             AutomationJobs.continue_applet_slice(
               %{
                 "job" => %{"id" => job.id},
                 "run" => %{"id" => head.id, "attemptId" => attempt.run.attempt_id}
               },
               %{"delaySeconds" => 60}
             )

    [delayed] =
      all_enqueued(
        worker: ExecuteRun,
        args: %{"automation_job_run_id" => head.id, "expected_slice_count" => 1}
      )

    publish_applet_fixture(ctx, String.replace(source, "serial_fifo", "parallel"), 1)
    assert_enqueued(worker: ExecuteRun, args: %{"automation_job_run_id" => tail.id})

    [unchanged] =
      all_enqueued(
        worker: ExecuteRun,
        args: %{"automation_job_run_id" => head.id, "expected_slice_count" => 1}
      )

    assert unchanged.scheduled_at == delayed.scheduled_at
    assert :ok = execute(tail.id)
    assert AutomationJobs.get_run_record(tail.id).status == :succeeded
  end

  test "a cancelled service Job does not report a Human revocation", ctx do
    publish_applet_fixture(ctx, "export default {actions:{work:{handler:()=>true}}}")
    job = job(ctx)
    run = enqueue(ctx, "cancelled")

    {:ok, _} =
      Repo.transact_top_level(fn ->
        Ankole.Ash.update(AutomationJobs.lock_job_in_tx(job.id), :cancel, %{
          cancelled_at: DateTime.utc_now()
        })
      end)

    assert :ok = execute(run.id)

    assert %{status: :cancelled, error: "automation job is cancelled", attempts: 0} =
             AutomationJobs.get_run_record(run.id)
  end

  defp job(ctx) do
    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    {:ok, _} =
      Signals.put_event_binding(ctx.actor, %{
        config_ref: "applet://#{ctx.page.id}",
        automation_job_id: job.id
      })

    job
  end

  defp busy_routes do
    original = :sys.get_state(EndpointPool)
    {:ok, shared, lease} = EndpointPool.checkout()
    EndpointPool.release(lease)
    server = start_supervised!({Bandit, plug: {BusyRoutes, shared}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    endpoint = %{shared | ip: {127, 0, 0, 1}, host: "127.0.0.1", port: port, url: url}
    {:ok, _} = Ankole.AppConfigure.put_global_by_key("pod.applet.action_runtime_url", shared.url)

    :sys.replace_state(
      EndpointPool,
      &%{&1 | uri: URI.parse(url), endpoints: %{endpoint.ip => endpoint}}
    )

    on_exit(fn -> :sys.replace_state(EndpointPool, fn _ -> original end) end)
  end

  defp enqueue(ctx, id) do
    {:ok, %{receipts: [receipt]}} =
      Signals.emit("applet://#{ctx.page.id}", %{id: id, type: "test", data: %{}})

    AutomationJobs.get_run_record(receipt.automation_job_run_id)
  end

  defp state(job_id, key) do
    case State
         |> Ash.Query.filter(automation_job_id == ^job_id and state_key == ^key)
         |> Ankole.Ash.read_one!() do
      nil -> nil
      state -> state.value
    end
  end

  defp execute(id, slice \\ 0, attempt \\ 1),
    do:
      ExecuteRun.run(%Oban.Job{
        args: %{"automation_job_run_id" => id, "expected_slice_count" => slice},
        attempt: attempt,
        max_attempts: 5
      })
end
