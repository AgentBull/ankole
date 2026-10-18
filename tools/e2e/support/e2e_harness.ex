defmodule Ankole.E2E.Harness do
  @moduledoc """
  Shared setup and assertions for the Lark e2e suites.

  The signals path is network-level end to end: a fake Feishu server speaks the
  real WS long-connection protocol to the real `plugins/lark_adapter` client,
  and the real `LarkAdapter.Delivery` sends real HTTP back to it. LLM behavior is
  controlled by the fake OpenAI upstream (or a real provider in the real-LLM
  suite). The worker under test is the real Agent Computer process in Docker.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.OpaqueContent
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.SweepJob
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.E2E.FakeOpenAIPlug
  alias Ankole.E2E.WaitHelpers
  alias Ankole.JSON
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.SlackAdapter.Config, as: SlackConfig
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Signals.Bindings
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.Delivery.Intent

  import Ecto.Query

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @long_lease_seconds 31_536_000

  # One Lark app per binding models the real platform: a bot only receives
  # events for chats it is in, so pushes target one app's WS connection.
  @primary_app_id "cli_chaos_lark"
  @record_app_id "cli_chaos_record"
  @ambient_app_id "cli_chaos_ambient"
  @multi_a_app_id "cli_chaos_multi_a"
  @secondary_app_id "cli_chaos_lark_b"
  @app_secret "secret-chaos"

  @doc "Observes a provider conversation through its real binding for a transport fixture."
  def observe_external_conversation!(agent_uid, binding_name, provider_id) do
    {:ok, binding} = Bindings.get_binding(agent_uid, binding_name)

    {:ok, conversation} =
      Repo.transact(fn repo ->
        External.observe_conversation_in_tx(
          repo,
          binding,
          %{provider_conversation_id: provider_id, external_kind: :im_group, reply_mode: :entry},
          DateTime.utc_now(:microsecond)
        )
      end)

    conversation
  end

  @doc "Returns the fixed timestamp used to keep scenario ordering stable."
  def base_time, do: @base_time

  @doc "Returns the long lease used by slow worker e2e turns."
  def long_lease_seconds, do: @long_lease_seconds

  @doc "App id whose connection carries primary-binding chats."
  def primary_app_id, do: @primary_app_id

  @doc "App id whose connection carries record-binding chats."
  def record_app_id, do: @record_app_id

  @doc "App id whose connection carries ambient-binding chats."
  def ambient_app_id, do: @ambient_app_id

  @doc "App id used by the primary agent's multi-agent-room binding."
  def multi_a_app_id, do: @multi_a_app_id

  @doc "App id used by the secondary agent's binding."
  def secondary_app_id, do: @secondary_app_id

  @doc """
  Cleans up committed fixtures for a serial test tagged `sandbox: false`.

  Timed lifecycle tests need real transaction boundaries: PostgreSQL `now()`
  stays fixed inside a sandbox transaction. Container cleanup runs before this
  callback. These tests must not share their database with another suite.
  """
  def cleanup_committed_fixtures_on_exit! do
    tenant_id = Repo.tenant_id!()
    drivers = Ankole.SessionsCase.driver_pids()
    principals = Repo.all(from(p in Principals.Principal, select: p.uid))
    workers = Repo.all(from(w in AgentWorker, select: w.agent_uid))
    providers = Repo.all(from(p in ProviderConfigs.Provider, select: p.provider_id))
    worker_providers = Enum.map(AgentWorkers.Providers.list(), & &1.provider_id)
    jobs = Repo.all(from(j in Oban.Job, select: j.id))
    objects = Repo.all(from(o in Ankole.Brain.Schemas.Object, select: o.id))

    scopes =
      Repo.all(from(c in Ankole.AppConfigure.AppConfig, distinct: c.scope, select: c.scope))

    conversations = Repo.all(from(c in Conversation, select: c.id))

    on_exit(
      Repo.bind_tenant(fn ->
        Ankole.SessionsCase.stop_new_drivers(drivers)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          created = Repo.all(from(p in Principals.Principal, where: p.uid not in ^principals))
          uids = Enum.map(created, & &1.uid)

          Repo.delete_all(from(o in Ankole.Brain.Schemas.Object, where: o.id not in ^objects))
          Repo.delete_all(from(c in Ankole.AppConfigure.AppConfig, where: c.scope not in ^scopes))
          # Shared conversations contain the committed fixture statements.
          Repo.delete_all(from(c in Conversation, where: c.id not in ^conversations))
          # The owner foreign key is RESTRICT. Delete Agents before their Humans.
          Repo.delete_all(
            from(p in Principals.Principal, where: p.uid in ^uids and p.type == :agent)
          )

          Repo.delete_all(
            from(r in Principals.AccessRestriction, where: r.principal_uid in ^uids)
          )

          Repo.delete_all(from(e in Principals.AccessEvent, where: e.principal_uid in ^uids))
          Repo.delete_all(from(p in Principals.Principal, where: p.uid in ^uids))
          Repo.delete_all(from(w in AgentWorker, where: w.agent_uid not in ^workers))

          Repo.delete_all(
            from(j in Oban.Job,
              where: j.id not in ^jobs and j.args["tenant_id"] == ^tenant_id
            )
          )

          Repo.delete_all(
            from(p in ProviderConfigs.Provider, where: p.provider_id not in ^providers)
          )

          for provider <- AgentWorkers.Providers.list(),
              provider.provider_id not in worker_providers do
            assert {:ok, _provider} = AgentWorkers.Providers.delete(provider.provider_id)
          end

          if tenant = Repo.get(Ankole.Tenants.Tenant, tenant_id) do
            assert {:ok, _} = Ankole.Tenants.delete(tenant)

            worker = Oban.Worker.to_string(Ankole.Tenants.Jobs.Delete)

            job =
              Repo.one!(
                from(j in Oban.Job,
                  where: j.worker == ^worker and j.args["tenant_id"] == ^tenant_id,
                  where: j.state in ["available", "scheduled", "retryable"]
                )
              )

            # Other tenants can still have platform jobs. Teardown runs only
            # this tenant's persisted delete job through its original owner.
            assert {:ok, true} =
                     WaitHelpers.wait_until(WaitHelpers.deadline(60_000), fn ->
                       result = Ankole.Tenants.Jobs.Delete.perform(job)
                       assert result == :ok or match?({:snooze, _}, result), inspect(result)
                       Ankole.Tenants.get(tenant_id) == {:error, :not_found}
                     end)

            Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
          end

          :ok = Ankole.AppConfigure.Cache.clear_for_test()
        end)
      end)
    )
  end

  def start_fake_llm_server! do
    server =
      start_supervised!(
        {Bandit, plug: FakeOpenAIPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc """
  Starts the fake Feishu platform (State + Bandit HTTP/WS listener) under the
  current ExUnit test supervisor with the standard e2e app credentials, and
  returns `%{state:, base_url:, port:}`.
  """
  def start_fake_feishu!(opts \\ []) do
    apps =
      Keyword.get(opts, :apps, [
        {@primary_app_id, @app_secret},
        {@record_app_id, @app_secret},
        {@ambient_app_id, @app_secret},
        {@multi_a_app_id, @app_secret},
        {@secondary_app_id, @app_secret}
      ])

    state = start_supervised!({FakeFeishu.State, owner: self()})

    server =
      start_supervised!(
        {Bandit,
         plug: {Keyword.get(opts, :platform_plug, FakeFeishu.Router), state: state},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    for {app_id, app_secret} <- apps do
      :ok =
        FakeFeishu.State.register_app(state, app_id, app_secret,
          bot_open_id: e2e_bot_open_id(app_id)
        )
    end

    base_url = "http://127.0.0.1:#{port}"
    put_lark_test_client_opts!(base_url: base_url)
    %{state: state, base_url: base_url, port: port}
  end

  # The historical e2e bot identities: the multi-agent apps carry distinct
  # bots, every other e2e app shares "ou_bot" so `lark_bot_mention/0` defaults
  # keep addressing the bot.
  defp e2e_bot_open_id(@multi_a_app_id), do: "ou_lark_bot_a"
  defp e2e_bot_open_id(@secondary_app_id), do: "ou_lark_bot_b"
  defp e2e_bot_open_id(_app_id), do: "ou_bot"

  @doc """
  Derives real long connections from enabled bindings and waits for the WS
  handshake against the fake Feishu server.

  Uses the production connection owner and stops the connections this call
  starts when the test ends. `connections:` is the number of WS connections.
  """
  def start_lark_connections!(fake_feishu, opts \\ []) do
    %{registry: registry, supervisor: supervisor} =
      ConnectionReconciler.__connection_lifecycle__()

    tenant_id = Repo.tenant_id!()
    existing = MapSet.new(ConnectionReconciler.registered_keys())
    result = ConnectionReconciler.reconcile_once()

    started =
      ConnectionReconciler.registered_keys()
      |> Enum.filter(fn key ->
        not MapSet.member?(existing, key) or
          match?([{_pid, {^tenant_id, _fingerprint}}], Registry.lookup(registry, key))
      end)

    on_exit(fn -> Enum.each(started, &ConnectionReconciler.stop/1) end)
    assert %{errors: []} = result

    expected = Keyword.get(opts, :connections, 1)

    assert {:ok, _count} =
             WaitHelpers.wait_until(WaitHelpers.deadline(20_000), fn ->
               count = FakeFeishu.State.connection_count(fake_feishu.state)
               count >= expected && count
             end),
           "expected #{expected} live fake Feishu WS connections"

    %{registry: registry, supervisor: supervisor}
  end

  @control_plane_server_id :e2e_control_plane_http_server

  def start_ai_gateway_test_http_server!(port \\ 0) do
    server =
      start_supervised!(
        {Bandit,
         plug: AnkoleWeb.Endpoint, scheme: :http, ip: {0, 0, 0, 0}, port: port, startup_log: false},
        id: @control_plane_server_id
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    old_env =
      Application.fetch_env(:ankole, Ankole.Sessions.AIGatewayAPIKeyBroker)

    Application.put_env(:ankole, Ankole.Sessions.AIGatewayAPIKeyBroker,
      base_url: "http://host.docker.internal:#{port}/api/v1/ai-gateway"
    )

    # The Docker worker pulls and pushes relay files at this same host-bound
    # server, not at the endpoint's configured loopback port.
    old_origin = Application.fetch_env(:ankole, :runtime_fabric_internal_origin)

    Application.put_env(
      :ankole,
      :runtime_fabric_internal_origin,
      "http://host.docker.internal:#{port}"
    )

    on_exit(fn ->
      case old_env do
        {:ok, value} ->
          Application.put_env(
            :ankole,
            Ankole.Sessions.AIGatewayAPIKeyBroker,
            value
          )

        :error ->
          Application.delete_env(
            :ankole,
            Ankole.Sessions.AIGatewayAPIKeyBroker
          )
      end

      case old_origin do
        {:ok, value} -> Application.put_env(:ankole, :runtime_fabric_internal_origin, value)
        :error -> Application.delete_env(:ankole, :runtime_fabric_internal_origin)
      end
    end)

    port
  end

  @doc """
  Starts the full worker e2e stack one suite test needs:

  fake OpenAI upstream + fake Feishu platform + agent domain + control-plane
  HTTP server (Worker Channel and AIGateway) + the real Docker Worker of each
  domain Agent, then waits for WS connections and for every Worker to be
  ready. Returns the ctx map the scenario functions consume.

  Options: `secondary: true` adds the second agent/app, `multi_agent: true`
  adds the multi-agent-room bindings, `real_llm_api_key:` switches the domain
  to the real OpenRouter provider (no fake LLM assertions), `worker: false`
  runs Worker reconciliation without waiting for initial Worker readiness,
  `automatic_signal_wakeups: false` leaves due Session wakeups for the test
  to drive explicitly, and `replaces_workers: true` lets the test kill, stop, or
  replace its Workers (see `start_worker!/2`).
  """
  def start_worker_e2e_stack!(opts \\ []) do
    Ankole.E2E.DockerWorker.assert_docker_image!()
    assert {:ok, _state} = Ankole.E2E.FakeOpenAIState.start_link(self())

    fake_llm_port = start_fake_llm_server!()
    fake_feishu = start_fake_feishu!(Keyword.get(opts, :fake_feishu_opts, []))

    {domain, connections} =
      case Keyword.get(opts, :real_llm_api_key) do
        nil ->
          domain = setup_lark_domain!(fake_llm_port, fake_feishu)
          {domain, 3}

        api_key ->
          {setup_lark_real_llm_domain!(api_key, fake_feishu), 3}
      end

    {domain, connections} =
      case Keyword.get(opts, :secondary, false) do
        true ->
          secondary =
            setup_lark_secondary_domain!(fake_llm_port, fake_feishu, user_name: "Agent B")

          {Map.put(domain, :secondary_agent, secondary.agent), connections + 1}

        false ->
          {domain, connections}
      end

    {domain, connections} =
      case Keyword.get(opts, :multi_agent, false) do
        true ->
          setup_multi_agent_binding!(domain.agent.uid, fake_feishu)
          {domain, connections + 1}

        false ->
          {domain, connections}
      end

    start_lark_connections!(fake_feishu, connections: connections)

    ctx = Map.merge(domain, %{fake_feishu: fake_feishu, fake_llm_port: fake_llm_port})

    case Keyword.get(opts, :worker, true) do
      false ->
        port = start_ai_gateway_test_http_server!()
        Ankole.E2E.DockerWorker.install_provider!(worker_endpoint(port))
        start_worker_reconciler!(opts)
        Map.put(ctx, :server_port, port)

      true ->
        agent_uids =
          [domain.agent.uid] ++
            case domain do
              %{secondary_agent: secondary} -> [secondary.uid]
              _domain -> []
            end

        worker_opts = Keyword.take(opts, [:replaces_workers, :automatic_signal_wakeups])
        Map.merge(ctx, start_worker!(agent_uids, worker_opts))
    end
  end

  @doc """
  Starts the control-plane HTTP server that Workers reach (Worker Channel and
  AIGateway), makes the control plane create Workers with its Docker provider,
  and waits until the Worker of each Agent is ready. Returns
  `%{container:, endpoint:, server_port:}`, where `container` is the Worker
  of the first Agent.

  The supervisor in the image starts a crashed Worker process again in its
  container, and the control plane replaces an instance that is gone, so a
  Turn can still finish after a crash. Thus the test fails at its end when
  one of these Workers has a different generation or incarnation than when
  it became ready. A test that kills, stops, or replaces its Workers on
  purpose gives `replaces_workers: true`.
  """
  def start_worker!([first | _rest] = agent_uids, opts \\ []) do
    port = Keyword.get(opts, :server_port) || start_ai_gateway_test_http_server!()
    endpoint = worker_endpoint(port)
    Ankole.E2E.DockerWorker.install_provider!(endpoint)
    start_worker_reconciler!(opts)

    Enum.each(agent_uids, &request_worker!/1)

    unless Keyword.get(opts, :replaces_workers, false),
      do: assert_workers_kept_on_exit!(agent_uids)

    %{container: Ankole.E2E.DockerWorker.container(first), endpoint: endpoint, server_port: port}
  end

  # The callback runs before the Worker containers are removed, so a failure
  # shows the log of the current container.
  defp assert_workers_kept_on_exit!(agent_uids) do
    started = Map.new(agent_uids, &{&1, worker_identity(&1)})

    # Committed fixtures need their own checkout during on_exit. Shared Sandbox
    # fixtures must keep using the transaction that owns their Worker rows.
    # Probe from a new process so an existing allowance cannot reuse that owner.
    committed? =
      Repo.bind_tenant(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Enum.all?(started, fn {agent_uid, _identity} ->
            not is_nil(worker_identity(agent_uid))
          end)
        end)
      end)
      |> Task.async()
      |> Task.await(15_000)

    on_exit(
      Repo.bind_tenant(fn ->
        check = fn ->
          Enum.each(started, fn {agent_uid, identity} ->
            current = worker_identity(agent_uid)

            if current != identity do
              logs = Ankole.E2E.DockerWorker.logs(Ankole.E2E.DockerWorker.container(agent_uid))

              flunk(
                "the Worker of #{agent_uid} changed while the test ran: #{inspect(identity)} " <>
                  "became #{inspect(current)}; logs=#{inspect(logs, printable_limit: :infinity)}"
              )
            end
          end)
        end

        if committed?,
          do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, check),
          else: check.()
      end)
    )
  end

  defp worker_identity(agent_uid) do
    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{generation: generation, incarnation_id: incarnation_id} ->
        %{generation: generation, incarnation_id: incarnation_id}

      nil ->
        nil
    end
  end

  @doc """
  Requests the Worker for work that needs the Agent computer, and waits until
  it is ready. Returns the container handle of that Worker.
  """
  def request_worker!(agent_uid) do
    :ok = AgentWorkers.request(agent_uid)
    container = Ankole.E2E.DockerWorker.container(agent_uid)

    assert {:ok, _worker} =
             WaitHelpers.wait_for_worker(container, WaitHelpers.deadline(120_000))

    container
  end

  @doc """
  Puts one file into an Agent's drive, as the Console or `ankole-files put`
  does. A Skill is installed at `skills/<name>/`; the Worker materializes it
  into `installed-skills/<name>/` of its Agent Home before the next turn.
  """
  def put_drive_file!(agent_uid, path, content, opts \\ []) do
    assert {:ok, %{sha256: sha256}} = Ankole.Files.store(content)

    upsert =
      Ankole.Attrs.maybe_put(
        %{path: path, sha256: sha256, source: "agent"},
        :mode,
        Keyword.get(opts, :mode)
      )

    assert {:ok, _result} = Ankole.Files.commit(agent_uid, [upsert])
    :ok
  end

  @doc "Worker Channel URL for a Docker worker against a host-bound control-plane port."
  def worker_endpoint(port) when is_integer(port) do
    "ws://host.docker.internal:#{port}/runtime-fabric/worker"
  end

  # Oban runs in manual mode in tests. This process runs the Worker lifecycle
  # and durable Session wakeup jobs that a deployment consumes. It drains
  # due jobs every 200 ms and sweeps every 5 seconds, with the provider
  # instances every 30 seconds.
  defp start_worker_reconciler!(opts) do
    automatic_signal_wakeups? = Keyword.get(opts, :automatic_signal_wakeups, true)

    spec = %{
      id: :e2e_worker_reconciler,
      start:
        {Task, :start_link,
         [Repo.bind_tenant(fn -> reconcile_workers(0, automatic_signal_wakeups?) end)]}
    }

    case start_supervised(spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      error -> flunk("E2E runtime reconciler did not start: #{inspect(error)}")
    end
  end

  defp reconcile_workers(round, automatic_signal_wakeups?) do
    if rem(round, 25) == 0 do
      :ok = SweepJob.perform(%Oban.Job{args: %{"objects" => rem(round, 150) == 0}})
    end

    now = DateTime.utc_now(:microsecond)
    Oban.drain_queue(queue: :agent_workers, with_scheduled: now)

    if automatic_signal_wakeups?,
      do: Oban.drain_queue(queue: :conversations, with_scheduled: now, with_limit: 20)

    Process.sleep(200)
    reconcile_workers(round + 1, automatic_signal_wakeups?)
  end

  @doc """
  Creates an e2e agent with the human owner every Agent now requires.
  """
  def create_e2e_agent!(attrs) do
    owner_uid = "human-e2e-owner-#{System.unique_integer([:positive])}"

    assert {:ok, %{principal: owner}} =
             Principals.create_human(%{
               display_name: "E2E Agent Owner",
               email: "#{owner_uid}@example.com"
             })

    assert {:ok, %{principal: _agent} = result} =
             Principals.create_agent(
               attrs
               |> Map.delete(:uid)
               |> Map.delete("uid")
               |> Map.put_new_lazy(:handle, fn ->
                 "e2e-agent-#{System.unique_integer([:positive])}"
               end)
               |> Map.put(:owner_principal_uid, owner.uid)
               |> Map.put_new_lazy(:worker_provider_id, &Ankole.E2E.DockerWorker.provider_id!/0)
             )

    result
  end

  def setup_lark_domain!(fake_llm_port, fake_feishu, agent_attrs \\ %{}) do
    uid =
      "agent-lark-e2e-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "fake-openrouter-e2e-#{Ecto.UUID.generate()}"

    %{principal: agent} =
      create_e2e_agent!(
        Map.merge(
          %{uid: uid, display_name: "Lark Chaos Agent", role: "Reliability test agent"},
          agent_attrs
        )
      )

    create_fake_llm_provider!(provider_id, fake_llm_port, "sk-fake-chaos")

    for {profile, model} <- [{"primary", "fake-main-chaos"}, {"light", "fake-light-chaos"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options: %{}
               })
    end

    primary_binding =
      upsert_lark_binding!(agent.uid, "lark-chaos-primary", :ignore, fake_feishu,
        app_id: @primary_app_id,
        group_message_mode: "addressed_only"
      )

    record_binding =
      upsert_lark_binding!(agent.uid, "lark-chaos-record", :record_only, fake_feishu,
        app_id: @record_app_id,
        group_message_mode: "observe_all"
      )

    ambient_binding =
      upsert_lark_binding!(agent.uid, "lark-chaos-ambient", :may_intervene, fake_feishu,
        app_id: @ambient_app_id,
        group_message_mode: "may_intervene"
      )

    %{
      agent: agent,
      primary_binding: primary_binding,
      record_binding: record_binding,
      ambient_binding: ambient_binding
    }
  end

  def setup_lark_secondary_domain!(fake_llm_port, fake_feishu, opts \\ []) do
    uid =
      "agent-lark-e2e-secondary-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "fake-chaos2-#{Ecto.UUID.generate()}"

    %{principal: agent} =
      create_e2e_agent!(%{
        uid: uid,
        display_name: "Lark Chaos Secondary Agent",
        role: "Second reliability test agent"
      })

    create_fake_llm_provider!(provider_id, fake_llm_port, "sk-fake-chaos-secondary")

    for {profile, model} <- [{"primary", "fake-main-chaos"}, {"light", "fake-light-chaos"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options: %{}
               })
    end

    primary_binding =
      upsert_lark_binding!(
        agent.uid,
        "lark-chaos-secondary",
        :ignore,
        fake_feishu,
        Keyword.merge(
          [app_id: @secondary_app_id, group_message_mode: "addressed_only"],
          opts
        )
      )

    %{agent: agent, primary_binding: primary_binding}
  end

  def setup_lark_real_llm_domain!(openrouter_api_key, fake_feishu) do
    uid =
      "agent-lark-real-llm-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "openrouter-lark-real-#{Ecto.UUID.generate()}"

    %{principal: agent} =
      create_e2e_agent!(%{
        uid: uid,
        display_name: "Lark Real LLM Agent",
        role: "Reliability test agent"
      })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => openrouter_api_key}]
               }
             })

    for {profile, model} <- [
          {"primary", "deepseek/deepseek-v4.1-flash"},
          {"light", "deepseek/deepseek-v4.1-flash"}
        ] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model
               })
    end

    primary_binding =
      upsert_lark_binding!(agent.uid, "lark-real-llm-primary", :ignore, fake_feishu,
        app_id: @primary_app_id,
        group_message_mode: "addressed_only"
      )

    record_binding =
      upsert_lark_binding!(agent.uid, "lark-real-llm-record", :record_only, fake_feishu,
        app_id: @record_app_id,
        group_message_mode: "observe_all"
      )

    ambient_binding =
      upsert_lark_binding!(agent.uid, "lark-real-llm-ambient", :may_intervene, fake_feishu,
        app_id: @ambient_app_id,
        group_message_mode: "may_intervene"
      )

    %{
      agent: agent,
      primary_binding: primary_binding,
      record_binding: record_binding,
      ambient_binding: ambient_binding,
      provider_id: provider_id
    }
  end

  @doc """
  Adds the primary agent's multi-agent-room binding (its own Lark app with a
  distinct bot identity) used by the mention-isolation scenario.
  """
  def setup_multi_agent_binding!(agent_uid, fake_feishu) do
    upsert_lark_binding!(agent_uid, "lark-chaos-multi-a", :ignore, fake_feishu,
      app_id: @multi_a_app_id,
      group_message_mode: "addressed_only",
      user_name: "Agent A"
    )
  end

  @doc """
  Creates one enabled Lark binding plus its encrypted AppConfigure chat config.

  The fake provider endpoint is injected at the connection boundary, so the
  production AppConfigure contract does not gain a provider URL override.
  """
  def upsert_lark_binding!(agent_uid, name, policy, _fake_feishu, opts) do
    app_id = Keyword.fetch!(opts, :app_id)

    config = %{
      "appID" => app_id,
      "appSecret" => @app_secret,
      "domain" => "feishu",
      "userName" => Keyword.get(opts, :user_name, "Lark Chaos Bot")
    }

    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(agent_uid, "lark", name, %{
               "config" => config,
               "group_message_mode" => Keyword.fetch!(opts, :group_message_mode),
               "unmatched_sender_policy" => "create_standalone"
             })

    assert binding.unaddressed_group_message_policy == policy

    binding
  end

  defp create_fake_llm_provider!(provider_id, fake_llm_port, api_key) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai_compatible",
               # Provider upstream calls originate from host-side AIGateway, not
               # from the Docker worker, so localhost is correct here.
               base_url: "http://127.0.0.1:#{fake_llm_port}",
               credential_pool: %{
                 "entries" => [
                   %{"label" => "Primary", "api_key" => api_key},
                   %{"label" => "Fallback", "api_key" => api_key <> "-fallback"}
                 ]
               }
             })
  end

  @doc """
  Waits for one Signal created from a provider entry.

  WS dispatch is asynchronous. The wait loop runs due Oban batch jobs and
  checks whether the exact Signal exists.
  """
  def signal_by_provider_message_id!(agent_uid, provider_message_id, timeout_ms \\ 20_000) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           finalize_due_inbound_batch_events!()
           signals_for(agent_uid, provider_message_id) |> List.first()
         end) do
      {:ok, %Signal{} = input} ->
        input

      :timeout ->
        flunk("no Signal for provider_message_id=#{provider_message_id} agent_uid=#{agent_uid}")
    end
  end

  @doc "Returns the newest pending (not completed) Signal for one entry, or nil."
  def pending_signal(agent_uid, provider_message_id) do
    Signal
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.provider_message_id == ^provider_message_id)
    |> where([input], is_nil(input.completed_at))
    |> order_by([input], desc: input.inserted_at, desc: input.id)
    |> limit(1)
    |> Repo.one()
  end

  defp signals_for(agent_uid, provider_message_id) do
    Signal
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.provider_message_id == ^provider_message_id)
    |> order_by([input], desc: input.inserted_at, desc: input.id)
    |> Repo.all()
  end

  @doc """
  Waits until the WS client acked one pushed event, so "nothing was ingested"
  can be asserted deterministically afterwards.
  """
  def wait_for_event_ack!(fake_feishu, event_id, timeout_ms \\ 10_000) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           FakeFeishu.State.ack_code(fake_feishu.state, event_id)
         end) do
      {:ok, code} -> code
      :timeout -> flunk("WS client never acked event #{event_id}")
    end
  end

  def message_observation(provider_conversation_id, provider_message_id) do
    case External.get_conversation(Repo, provider_conversation_id) do
      %Conversation{id: id} -> External.get_message(Repo, id, provider_message_id)
      nil -> nil
    end
  end

  def wait_for_message_observation!(
        provider_conversation_id,
        provider_message_id,
        timeout_ms \\ 15_000
      ) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           message_observation(provider_conversation_id, provider_message_id)
         end) do
      {:ok, %{message: %ConversationMessage{}} = observation} -> observation
      :timeout -> flunk("no message for #{provider_conversation_id} / #{provider_message_id}")
    end
  end

  @doc "Waits until a recalled provider statement and its reference are removed."
  def wait_for_message_removed!(
        provider_conversation_id,
        provider_message_id,
        timeout_ms \\ 15_000
      ) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           is_nil(message_observation(provider_conversation_id, provider_message_id)) || nil
         end) do
      {:ok, true} ->
        :ok

      :timeout ->
        flunk("message #{provider_conversation_id}/#{provider_message_id} was not removed")
    end
  end

  def finalize_due_inbound_batch_events! do
    result =
      Oban.drain_queue(
        queue: :conversations,
        with_scheduled: DateTime.utc_now(:microsecond),
        with_limit: 20
      )

    assert result.failure == 0, inspect(result)
    :ok
  end

  def ensure_input_driver!(%Signal{} = event, _now) do
    with {:ok, pid} <- Ankole.Sessions.ensure_driver(event) do
      send(pid, {:inbox, event.id})
      {:ok, %{status: :driving, pid: pid}}
    end
  end

  def retry_until_sent!(input, now) do
    assert {:ok, _result} =
             WaitHelpers.wait_until(WaitHelpers.deadline(90_000), fn ->
               case ensure_input_driver!(input, now) do
                 {:ok, %{status: :driving} = result} -> result
                 {:error, _reason} -> nil
               end
             end),
           "input #{input.id} had no conversation driver"
  end

  @doc "Asserts one Signal finished, either by completion or recall hard delete."
  def assert_signal_finished!(signal_id) do
    assert {:ok, :finished} =
             WaitHelpers.wait_until(WaitHelpers.deadline(30_000), fn ->
               case Repo.get(Signal, signal_id) do
                 nil -> :finished
                 %Signal{completed_at: %DateTime{}} -> :finished
                 %Signal{} -> nil
               end
             end)
  end

  @doc "Asserts one Signal completed with a durable completion timestamp."
  def assert_signal_completed!(signal_id) do
    assert %DateTime{} = Repo.get!(Signal, signal_id).completed_at
  end

  @doc """
  Dispatches due intent rows through the real Lark adapter (real HTTP to the
  fake Feishu server).
  """
  def run_intent_dispatch! do
    Oban.drain_queue(
      queue: :outbox,
      with_scheduled: DateTime.utc_now(:microsecond),
      with_limit: 20
    )
  end

  @doc """
  Dispatches one committed intent row and asserts the message became visible on
  the fake Feishu platform with the expected text, operation, and target.

  Returns the updated (succeeded) intent row.
  """
  def dispatch_and_assert_lark_intent(
        fake_feishu,
        %Intent{} = intent,
        expected_text,
        operation,
        target
      ) do
    assert intent.payload["text"] =~ expected_text
    sent = dispatch_succeeded!(intent)

    message = platform_message!(fake_feishu, sent.created_provider_message_id)
    assert message.sender == :bot
    assert message.msg_type == "text"
    assert message.text =~ expected_text
    assert_platform_target(message, operation, target)
    sent
  end

  @doc """
  Asserts an ordinary streamed AI reply already landed on the fake Feishu
  platform and has a committed Message with its provider reference.
  """
  def assert_lark_final_reply(
        fake_feishu,
        %{message: %ConversationMessage{}, external_ref: _} = reply,
        expected_text,
        operation,
        target
      ) do
    assert final_reply_text(reply) =~ expected_text

    message = platform_message!(fake_feishu, reply.external_ref.provider_message_id)
    assert message.sender == :bot
    assert message.msg_type == "text"
    assert message.text =~ expected_text
    assert_platform_target(message, operation, target)
    reply
  end

  @doc """
  Dispatches one attachment intent row and asserts the platform-visible file
  message carries the content the worker actually produced.
  """
  def dispatch_and_assert_lark_file_intent(fake_feishu, %Intent{} = intent, target) do
    # The attachment row carries the file and no visible text. The answer rides
    # on the final reply row, so no adapter posts the same wall twice.
    assert is_nil(intent.payload["text"])

    assert [
             %{
               "path" => "reports/chaos-report.txt",
               "blob_ref" => blob_ref,
               "name" => "chaos-report.txt"
             }
           ] = intent.payload["attachments"]

    assert is_binary(blob_ref)

    sent = dispatch_succeeded!(intent)

    message = platform_message!(fake_feishu, sent.created_provider_message_id)
    assert message.sender == :bot
    assert message.msg_type == "file"
    assert {:ok, %{"file_key" => file_key}} = JSON.decode(message.content)
    assert_platform_target(message, :reply, target)

    upload = FakeFeishu.State.uploaded_file(fake_feishu.state, file_key)
    assert %{name: "chaos-report.txt", content: content} = upload
    assert content =~ "CHAOS_REPLY_ATTACHMENT_FILE"

    assert [%{"provider_file_key" => ^file_key}] = sent.payload["attachments"]
    sent
  end

  @doc """
  Runs one intent dispatch pass and asserts this row succeeded; returns the
  updated row (with `created_provider_message_id` from the provider response).
  """
  def dispatch_succeeded!(%Intent{outbound_key: key}) do
    results = run_intent_dispatch!()

    sent = Repo.get_by!(Intent, outbound_key: key)

    assert sent.status == :sent,
           "intent #{key} did not dispatch successfully: #{inspect(sent)} jobs=#{inspect(results)}"

    assert is_binary(sent.created_provider_message_id)
    sent
  end

  def platform_message!(fake_feishu, message_id) do
    message = FakeFeishu.State.message(fake_feishu.state, message_id)
    assert message, "no fake Feishu platform message #{inspect(message_id)}"
    message
  end

  defp assert_platform_target(message, :reply, target), do: assert(message.reply_to == target)
  defp assert_platform_target(message, :post, chat_id), do: assert(message.chat_id == chat_id)

  defp final_reply_text(%{message: %ConversationMessage{text: text}}), do: text || ""

  @doc "Returns function_call items (optionally by tool name) across messages."
  def function_call_items(messages, tool_name \\ nil) do
    messages
    |> Enum.flat_map(&message_items/1)
    |> Enum.filter(fn
      %{"type" => "function_call", "name" => name} -> is_nil(tool_name) or name == tool_name
      _item -> false
    end)
  end

  @doc "Returns direct function and custom tool calls, optionally by tool name."
  def tool_call_items(messages, tool_name \\ nil) do
    messages
    |> Enum.flat_map(&message_items/1)
    |> Enum.filter(fn
      %{"type" => type, "name" => name}
      when type in ["function_call", "custom_tool_call"] ->
        is_nil(tool_name) or name == tool_name

      _item ->
        false
    end)
  end

  @doc """
  Pairs direct function and custom tool calls with their matching outputs by
  call_id and returns decoded results in call order.

  The output payload is worker-owned JSON; when it does not decode as JSON the
  raw string is wrapped as `%{"raw" => output}`.
  """
  def tool_results(messages, tool_name \\ nil) do
    outputs =
      messages
      |> Enum.flat_map(&message_items/1)
      |> Enum.filter(fn
        %{"type" => type} when type in ["function_call_output", "custom_tool_call_output"] ->
          true

        _item ->
          false
      end)
      |> Map.new(fn item -> {{item["type"], item["call_id"]}, item["output"]} end)

    messages
    |> tool_call_items(tool_name)
    |> Enum.map(fn call ->
      output_type =
        if call["type"] == "custom_tool_call",
          do: "custom_tool_call_output",
          else: "function_call_output"

      arguments =
        if call["type"] == "custom_tool_call", do: call["input"], else: call["arguments"]

      %{
        tool_name: call["name"],
        call_id: call["call_id"],
        arguments: decode_json_or_raw(arguments),
        result: decode_json_or_raw(Map.get(outputs, {output_type, call["call_id"]}))
      }
    end)
  end

  @doc "Returns decoded results of one tool where the worker reported success."
  def successful_tool_results(messages, tool_name) do
    messages
    |> tool_results(tool_name)
    |> Enum.reject(&tool_result_error?/1)
    |> Enum.map(& &1.result)
  end

  @doc "True when at least one call of the tool completed without an error flag."
  def tool_result_succeeded?(messages, tool_name) do
    successful_tool_results(messages, tool_name) != []
  end

  @doc "True when a command tool call reported exit code 0."
  def command_tool_succeeded?(messages) do
    messages
    |> successful_tool_results("command")
    |> Enum.any?(fn
      %{"raw" => raw} when is_binary(raw) ->
        String.contains?(raw, "exit_code=0")

      result ->
        tool_detail(result, ["exitCode"]) == 0 or tool_detail(result, ["exit_code"]) == 0
    end)
  end

  @doc "True when the paired output is missing or carries an error flag."
  def tool_result_error?(%{result: nil}), do: true

  def tool_result_error?(%{result: %{"raw" => raw}}) when is_binary(raw) do
    String.starts_with?(raw, "Error:")
  end

  # `show_background_job_details` and other Job tools always carry a declared
  # `error` field, so only a present value means the call failed.
  def tool_result_error?(%{result: result}) when is_map(result) do
    Map.get(result, "is_error") == true or Map.get(result, "isError") == true or
      not is_nil(Map.get(result, "error"))
  end

  def tool_result_error?(_tool_result), do: true

  @doc """
  Digs a detail path out of one decoded tool result, tolerating both the
  wrapped (`result.details`) and flat (`details`) worker output shapes.
  """
  def tool_detail(result, path) when is_map(result) and is_list(path) do
    get_in(result, ["result", "details" | path]) ||
      get_in(result, ["details" | path]) ||
      get_in(result, path)
  end

  def tool_detail(_result, _path), do: nil

  @doc "Concatenated output text of one AI message."
  def message_text(%Message{} = message) do
    message
    |> message_items()
    |> Enum.flat_map(&item_text_parts/1)
    |> Enum.join("")
  end

  defp message_items(%Message{content: content}) when is_list(content), do: content
  defp message_items(_message), do: []

  defp item_text_parts(%{"type" => "message", "content" => parts}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{"type" => type, "text" => text}
      when type in ["output_text", "text"] and is_binary(text) ->
        [text]

      _part ->
        []
    end)
  end

  defp item_text_parts(%{"type" => type, "text" => text})
       when type in ["output_text", "text"] and is_binary(text),
       do: [text]

  defp item_text_parts(_item), do: []

  defp decode_json_or_raw(nil), do: nil

  defp decode_json_or_raw(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      {:error, _reason} -> decode_exit_code_output(value)
    end
  end

  defp decode_json_or_raw(value) when is_map(value), do: value

  defp decode_exit_code_output(value) do
    case Regex.run(~r/\Aexit_code=(\d+)(?:\n(.*))?\z/s, value) do
      [_match, exit_code, output] ->
        output
        |> decode_output_result()
        |> Map.put("exitCode", String.to_integer(exit_code))
        |> Map.put("raw", value)

      [_match, exit_code] ->
        %{"exitCode" => String.to_integer(exit_code), "raw" => value}

      _no_match ->
        decode_key_value_output(value)
    end
  end

  defp decode_output_result(output) when is_binary(output) do
    case JSON.decode(output) do
      {:ok, decoded} -> %{"result" => decoded}
      {:error, _reason} -> %{}
    end
  end

  defp decode_key_value_output(value) do
    details =
      value
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          ["exit_code", exit_code] -> Map.put(acc, "exitCode", String.to_integer(exit_code))
          _other -> acc
        end
      end)

    case details do
      map when map_size(map) > 0 -> Map.put(details, "raw", value)
      _empty -> %{"raw" => value}
    end
  end

  @doc """
  Reads the persisted trajectory messages of one Job Turn in position order.

  `Ankole.BackgroundAgentJobs.Turns` stores only the ankole_chatml header on the
  Turn row and keeps every semantic item in append-only TurnItem rows, so a raw
  Turn read never carries `messages`.
  """
  def job_turn_trajectory_messages(%{id: turn_id}) when is_binary(turn_id) do
    TurnItem
    |> where([item], item.turn_id == ^turn_id)
    |> order_by([item], asc: item.position)
    |> Repo.all()
    |> Enum.flat_map(fn item ->
      {messages, _truncated?} =
        item.item
        |> OpaqueContent.reveal()
        |> TurnItemProjection.project()

      messages
    end)
  end

  def lark_bot_mention(open_id \\ "ou_bot", key \\ "@_user_1", name \\ "Lark Chaos Bot"),
    do: %{"key" => key, "name" => name, "id" => %{"open_id" => open_id}}

  def openrouter_api_key! do
    System.get_env("OPENROUTER_API_KEY") ||
      System.get_env("OPEN_ROUTER_API_KEY") ||
      flunk("OPENROUTER_API_KEY or OPEN_ROUTER_API_KEY is required for real Lark LLM e2e")
  end

  @doc """
  Stops the control-plane HTTP server and starts it again on the same port, so
  every Worker connection drops and the Worker must reconnect.
  """
  def restart_control_plane_http_server!(port) when is_integer(port) do
    :ok = stop_supervised!(@control_plane_server_id)
    ^port = start_ai_gateway_test_http_server!(port)
    :ok
  end

  @doc "Sets a test-scoped Slack transport without storing its endpoint in binding config."
  def put_slack_test_client_opts!(client_opts) do
    previous = Application.fetch_env(:ankole, SlackConfig)
    current = Application.get_env(:ankole, SlackConfig, [])
    Application.put_env(:ankole, SlackConfig, Keyword.put(current, :client_opts, client_opts))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, SlackConfig, value)
        :error -> Application.delete_env(:ankole, SlackConfig)
      end
    end)
  end

  defp put_lark_test_client_opts!(client_opts) do
    previous = Application.fetch_env(:ankole, LarkConfig)
    current = Application.get_env(:ankole, LarkConfig, [])
    Application.put_env(:ankole, LarkConfig, Keyword.put(current, :client_opts, client_opts))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, LarkConfig, value)
        :error -> Application.delete_env(:ankole, LarkConfig)
      end
    end)
  end
end
