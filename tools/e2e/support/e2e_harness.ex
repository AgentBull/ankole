defmodule Ankole.E2E.Harness do
  @moduledoc """
  Shared setup and assertions for the Lark e2e suites.

  The signals path is network-level end to end: a fake Feishu server speaks the
  real WS long-connection protocol to the real `plugins/lark_adapter` client,
  and the real `LarkAdapter.Outbox` sends real HTTP back to it. LLM behavior is
  controlled by the fake OpenAI upstream (or a real provider in the real-LLM
  suite). The worker under test is the real Agent Computer process in Docker.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Ankole.AIAgent.Library
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.ActorRuntime.WorkerBrowserConfig
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.ReadyEventProcessor
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure
  alias Ankole.E2E.FakeFeishu
  alias Ankole.E2E.FakeOpenAIPlug
  alias Ankole.E2E.WaitHelpers
  alias Ankole.JSON
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

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

  # -- infrastructure ---------------------------------------------------------

  def start_fake_llm_server! do
    server =
      start_supervised!(
        {Bandit, plug: FakeOpenAIPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc """
  Starts the fake Feishu platform with the standard e2e app credentials.
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

    FakeFeishu.Server.start!(apps: apps)
  end

  @doc """
  Derives real long connections from enabled bindings and waits for the WS
  handshake against the fake Feishu server.

  Uses a test-scoped connection registry and supervisor so connections die with
  the test. `connections:` is the number of WS connections to wait for.
  """
  def start_lark_connections!(fake_feishu, opts \\ []) do
    suffix = System.unique_integer([:positive])
    registry = :"lark_e2e_conn_registry_#{suffix}"
    supervisor = :"lark_e2e_conn_supervisor_#{suffix}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

    result = ConnectionReconciler.reconcile_once(registry: registry, supervisor: supervisor)
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

  def start_ai_gateway_test_http_server! do
    server =
      start_supervised!(
        {Bandit,
         plug: AnkoleWeb.Endpoint, scheme: :http, ip: {0, 0, 0, 0}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    old_env = Application.fetch_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)

    # The Docker worker cannot reach the host's localhost; the broker setting
    # points it at the real Phoenix endpoint exposed on the Docker host gateway.
    Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker,
      worker_facing_base_url: "http://host.docker.internal:#{port}/api/v1/ai-gateway"
    )

    on_exit(fn ->
      case old_env do
        {:ok, value} ->
          Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker, value)

        :error ->
          Application.delete_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)
      end
    end)
  end

  def safe_stop_router do
    Broker.stop_router()
  catch
    :exit, _reason -> :ok
  end

  # -- suite stack --------------------------------------------------------------

  @doc """
  Starts the full worker e2e stack one suite test needs:

  fake OpenAI upstream + fake Feishu platform + agent domain (bindings with
  `baseUrl` pointing at fake Feishu) + RuntimeFabric router + AIGateway HTTP
  server + one real Docker worker, then waits for WS connections and worker
  admission. Returns the ctx map the scenario functions consume.

  Options: `secondary: true` adds the second agent/app, `multi_agent: true`
  adds the multi-agent-room bindings, `real_llm_api_key:` switches the domain
  to the real OpenRouter provider (no fake LLM assertions), `worker: false`
  skips the Docker worker.
  """
  def start_worker_e2e_stack!(opts \\ []) do
    Ankole.E2E.DockerWorker.assert_docker_image!()
    assert {:ok, _state} = Ankole.E2E.FakeOpenAIState.start_link(self())

    fake_llm_port = start_fake_llm_server!()
    fake_feishu = start_fake_feishu!()

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
            setup_lark_secondary_domain!(fake_llm_port, fake_feishu,
              bot_open_id: "ou_lark_bot_b",
              user_name: "Agent B"
            )

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
      false -> ctx
      true -> Map.merge(ctx, start_worker!(Keyword.get(opts, :worker_prefix, "lark-e2e")))
    end
  end

  @doc """
  Starts the RuntimeFabric router, the worker-facing AIGateway HTTP server, and
  one admitted Docker worker. Returns `%{container:, worker_id:, endpoint:, worker_auth_key:}`.
  """
  def start_worker!(prefix) do
    worker_id = "#{prefix}-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> safe_stop_router() end)
    start_ai_gateway_test_http_server!()

    container = start_additional_worker!(endpoint, worker_id, worker_auth_key)

    %{
      container: container,
      worker_id: worker_id,
      endpoint: endpoint,
      worker_auth_key: worker_auth_key
    }
  end

  @doc """
  Starts one more Docker worker against an already-running router and waits for
  its admission projection.
  """
  def start_additional_worker!(endpoint, worker_id, worker_auth_key) do
    container =
      Ankole.E2E.DockerWorker.start_docker_worker!(
        endpoint: Ankole.E2E.DockerWorker.docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> Ankole.E2E.DockerWorker.cleanup_docker_worker(container) end)

    assert {:ok, _worker} =
             WaitHelpers.wait_for_worker_projection(
               worker_id,
               container,
               WaitHelpers.deadline(90_000)
             )

    container
  end

  # -- domain setup -----------------------------------------------------------

  def setup_lark_domain!(fake_llm_port, fake_feishu) do
    uid =
      "agent-lark-e2e-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "fake-openrouter-e2e-#{Ecto.UUID.generate()}"
    assert {:ok, %{skills: _count}} = Library.sync_builtin_skills(force: true)

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
               uid: uid,
               display_name: "Lark Chaos Agent",
               role: "Reliability test agent"
             })

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

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
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
    assert {:ok, %{skills: _count}} = Library.sync_builtin_skills(force: true)

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
               uid: uid,
               display_name: "Lark Real LLM Agent",
               role: "Reliability test agent"
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{"api_key" => openrouter_api_key}
             })

    for {profile, model} <- [
          {"primary", "qwen/qwen3.5-flash-02-23"},
          {"light", "qwen/qwen3.5-flash-02-23"}
        ] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model
               })
    end

    maybe_put_real_llm_browser_cdp_config!(agent.uid)

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

  defp maybe_put_real_llm_browser_cdp_config!(agent_uid) do
    case System.get_env("ANKOLE_E2E_REMOTE_BROWSER_CDP_CONFIG") do
      value when value in [nil, ""] ->
        :ok

      json ->
        config = JSON.decode!(json)
        definition = WorkerBrowserConfig.remote_cdp_config_definition()

        assert :ok = WorkerBrowserConfig.ensure_registered()
        assert {:ok, ^config} = AppConfigure.put_for_agent(agent_uid, definition, config)

        :ok
    end
  end

  @doc """
  Adds the primary agent's multi-agent-room binding (its own Lark app with a
  distinct bot identity) used by the mention-isolation scenario.
  """
  def setup_multi_agent_binding!(agent_uid, fake_feishu) do
    upsert_lark_binding!(agent_uid, "lark-chaos-multi-a", :ignore, fake_feishu,
      app_id: @multi_a_app_id,
      group_message_mode: "addressed_only",
      bot_open_id: "ou_lark_bot_a",
      user_name: "Agent A"
    )
  end

  @doc """
  Creates one enabled Lark binding plus its encrypted AppConfigure chat config
  pointing `baseUrl` at the fake Feishu server.
  """
  def upsert_lark_binding!(agent_uid, name, policy, fake_feishu, opts) do
    app_id = Keyword.fetch!(opts, :app_id)

    config =
      %{
        "appId" => app_id,
        "appSecret" => @app_secret,
        "domain" => "feishu",
        "baseUrl" => fake_feishu.base_url,
        "platformSubjectNamespace" => "lark-chaos",
        "userName" => Keyword.get(opts, :user_name, "Lark Chaos Bot"),
        "group_message_mode" => Keyword.fetch!(opts, :group_message_mode)
      }
      |> maybe_put_config("botOpenId", Keyword.get(opts, :bot_open_id, "ou_bot"))
      |> maybe_put_config("botUserId", Keyword.get(opts, :bot_user_id))

    assert {:ok, _stored} =
             AppConfigure.put_global_by_key(LarkConfig.chat_config_key(name), config)

    assert {:ok, binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent_uid,
               name: name,
               adapter: "lark",
               config_ref: "app-config://#{LarkConfig.chat_config_key(name)}",
               filters: %{},
               unaddressed_group_message_policy: policy
             })

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
               connection_options: %{
                 "api_key" => api_key
               }
             })
  end

  # -- ingress waits ----------------------------------------------------------

  @doc """
  Waits for one pending actor event created from a provider entry.

  WS dispatch is asynchronous, so the test wait loop advances runtime-event
  deadlines and then checks whether the exact actor event exists.
  """
  def actor_event_by_source_entry_id!(agent_uid, source_entry_id, timeout_ms \\ 20_000) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           finalize_due_inbound_batch_events!()
           pending_actor_event(agent_uid, source_entry_id)
         end) do
      {:ok, %ActorEvent{} = input} ->
        input

      :timeout ->
        flunk(
          "no pending actor event for source_entry_id=#{source_entry_id} agent_uid=#{agent_uid}; " <>
            "existing=#{inspect(actor_events_for(agent_uid, source_entry_id))}"
        )
    end
  end

  @doc "Returns the newest pending (not completed) actor event for one entry, or nil."
  def pending_actor_event(agent_uid, source_entry_id) do
    ActorEvent
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.source_entry_id == ^source_entry_id)
    |> where([input], is_nil(input.completed_at))
    |> order_by([input], desc: input.inserted_at, desc: input.id)
    |> limit(1)
    |> Repo.one()
  end

  defp actor_events_for(agent_uid, source_entry_id) do
    ActorEvent
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.source_entry_id == ^source_entry_id)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, [:id, :type, :completed_at]))
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

  def wait_for_signal_entry!(signal_channel_id, source_entry_id, timeout_ms \\ 15_000) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           Repo.get_by(Entry,
             signal_channel_id: signal_channel_id,
             source_entry_id: source_entry_id
           )
         end) do
      {:ok, %Entry{} = entry} ->
        entry

      :timeout ->
        flunk("no signal entry for #{signal_channel_id} / #{source_entry_id}")
    end
  end

  @doc """
  Waits until the recall of one signal entry lands (mirror row gone or removed).
  """
  def wait_for_signal_entry_removed!(signal_channel_id, source_entry_id, timeout_ms \\ 15_000) do
    case WaitHelpers.wait_until(WaitHelpers.deadline(timeout_ms), fn ->
           is_nil(
             Repo.get_by(Entry,
               signal_channel_id: signal_channel_id,
               source_entry_id: source_entry_id
             )
           ) || nil
         end) do
      {:ok, true} -> :ok
      :timeout -> flunk("signal entry #{signal_channel_id}/#{source_entry_id} was not removed")
    end
  end

  # -- turn driving -----------------------------------------------------------

  def finalize_due_inbound_batch_events! do
    now = DateTime.utc_now(:microsecond) |> DateTime.add(120, :second)

    SignalsGateway.runtime_event_snapshot()
    |> Enum.filter(fn {channel, payload} ->
      channel == RuntimeEvents.inbound_batch_due_channel() and runtime_event_due?(payload, now)
    end)
    |> Enum.each(fn {_channel, payload} ->
      assert {:ok, _result} =
               SignalsGateway.finalize_inbound_batch_by_id(
                 Map.fetch!(payload, "batch_id"),
                 Map.fetch!(payload, "batch_revision"),
                 now: now
               )
    end)
  end

  defp runtime_event_due?(%{"due_at" => nil}, _now), do: true

  defp runtime_event_due?(%{"due_at" => due_at}, now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, due_at, _offset} -> DateTime.compare(due_at, now) != :gt
      _invalid -> false
    end
  end

  defp runtime_event_due?(_payload, _now), do: true

  def process_ready_event_for_actor!(%ActorEvent{} = event, now) do
    ReadyEventProcessor.process_ready_event_for_actor(
      %{agent_uid: event.agent_uid, session_id: event.session_id},
      now: now,
      lease_seconds: @long_lease_seconds
    )
  end

  @doc "Asserts one actor event finished, either by completion or recall hard delete."
  def assert_actor_event_finished!(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      nil -> :ok
      %ActorEvent{completed_at: %DateTime{}} -> :ok
      %ActorEvent{} = event -> flunk("actor event still pending: #{inspect(event)}")
    end
  end

  @doc "Asserts one actor event completed with a durable completion timestamp."
  def assert_actor_event_completed!(actor_event_id) do
    assert %DateTime{} = Repo.get!(ActorEvent, actor_event_id).completed_at
  end

  # -- outbox dispatch and platform-visible assertions --------------------------

  @doc """
  Dispatches due outbox rows through the real Lark adapter (real HTTP to the
  fake Feishu server).
  """
  def run_outbox_dispatch! do
    now = DateTime.utc_now(:microsecond)

    SignalsGateway.runtime_event_snapshot()
    |> Enum.filter(&outbox_due_event?(&1, now))
    |> Enum.take(20)
    |> Enum.map(fn {_channel, payload} ->
      SignalsGateway.dispatch_outbox(
        payload["agent_uid"],
        payload["binding_name"],
        payload["outbound_key"],
        LarkOutbox,
        now: now
      )
    end)
  end

  defp outbox_due_event?({channel, payload}, now) when is_map(payload) do
    channel == Ankole.RuntimeEvents.outbox_due_channel() and due_at?(payload["due_at"], now)
  end

  defp outbox_due_event?(_event, _now), do: false

  defp due_at?(nil, _now), do: true

  defp due_at?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, due_at, _offset} -> DateTime.compare(due_at, now) != :gt
      {:error, _reason} -> false
    end
  end

  defp due_at?(_value, _now), do: false

  @doc """
  Dispatches one committed outbox row and asserts the message became visible on
  the fake Feishu platform with the expected text, operation, and target.

  Returns the updated (succeeded) outbox row.
  """
  def dispatch_and_assert_lark_outbox(
        fake_feishu,
        %OutboxEntry{} = outbox,
        expected_text,
        operation,
        target
      ) do
    assert outbox.payload["text"] =~ expected_text
    sent = dispatch_outbox_succeeded!(outbox)

    message = platform_message!(fake_feishu, sent.created_source_entry_id)
    assert message.sender == :bot
    assert message.msg_type == "text"
    assert message.text =~ expected_text
    assert_platform_target(message, operation, target)
    sent
  end

  @doc """
  Asserts an ordinary streamed AI reply already landed on the fake Feishu
  platform and has a final `signal_gateway_entries.ai_message_id` mirror.
  """
  def assert_lark_final_reply(
        fake_feishu,
        %Entry{} = reply,
        expected_text,
        operation,
        target
      ) do
    assert final_reply_text(reply) =~ expected_text

    message = platform_message!(fake_feishu, reply.source_entry_id)
    assert message.sender == :bot
    assert message.msg_type == "text"
    assert message.text =~ expected_text
    assert_platform_target(message, operation, target)
    reply
  end

  @doc """
  Dispatches one attachment outbox row and asserts the platform-visible file
  message carries the content the worker actually produced.
  """
  def dispatch_and_assert_lark_file_outbox(fake_feishu, %OutboxEntry{} = outbox, target) do
    assert outbox.payload["text"] =~ "CHAOS_REPLY_ATTACHMENT_OK"

    assert [
             %{
               "user_files_relative_path" => "reports/chaos-report.txt",
               "name" => "chaos-report.txt"
             }
           ] = outbox.payload["attachments"]

    sent = dispatch_outbox_succeeded!(outbox)

    message = platform_message!(fake_feishu, sent.created_source_entry_id)
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
  Runs one outbox dispatch pass and asserts this row succeeded; returns the
  updated row (with `created_source_entry_id` from the provider response).
  """
  def dispatch_outbox_succeeded!(%OutboxEntry{outbound_key: key}) do
    results = run_outbox_dispatch!()

    sent =
      Enum.find_value(results, fn
        {:ok, %OutboxEntry{outbound_key: ^key, status: :succeeded} = row} -> row
        _other -> nil
      end)

    assert sent, "outbox #{key} did not dispatch successfully: #{inspect(results)}"
    assert is_binary(sent.created_source_entry_id)
    sent
  end

  def platform_message!(fake_feishu, message_id) do
    message = FakeFeishu.State.message(fake_feishu.state, message_id)
    assert message, "no fake Feishu platform message #{inspect(message_id)}"
    message
  end

  defp assert_platform_target(message, :reply, target), do: assert(message.reply_to == target)
  defp assert_platform_target(message, :post, chat_id), do: assert(message.chat_id == chat_id)

  defp final_reply_text(%Entry{text: text, fallback_visible_text: fallback}) do
    text || fallback || ""
  end

  # -- AI message (Responses) tool-result surface -------------------------------

  @doc "Returns function_call items (optionally by tool name) across messages."
  def function_call_items(messages, tool_name \\ nil) do
    messages
    |> Enum.flat_map(&message_items/1)
    |> Enum.filter(fn
      %{"type" => "function_call", "name" => name} -> is_nil(tool_name) or name == tool_name
      _item -> false
    end)
  end

  @doc """
  Pairs function_call items with their function_call_output items by call_id
  and returns decoded results in call order.

  The output payload is worker-owned JSON; when it does not decode as JSON the
  raw string is wrapped as `%{"raw" => output}`.
  """
  def tool_results(messages, tool_name \\ nil) do
    outputs =
      messages
      |> Enum.flat_map(&message_items/1)
      |> Enum.filter(&match?(%{"type" => "function_call_output"}, &1))
      |> Map.new(fn item -> {item["call_id"], item["output"]} end)

    messages
    |> function_call_items(tool_name)
    |> Enum.map(fn call ->
      %{
        tool_name: call["name"],
        call_id: call["call_id"],
        arguments: decode_json_or_raw(call["arguments"]),
        result: decode_json_or_raw(Map.get(outputs, call["call_id"]))
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
    String.starts_with?(raw, "Error:") or
      Regex.match?(~r/<ankole_untrusted_tool_output[^>]*>\s*Error:/, raw)
  end

  def tool_result_error?(%{result: result}) when is_map(result) do
    Map.get(result, "is_error") == true or Map.get(result, "isError") == true or
      Map.has_key?(result, "error")
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
    value = unwrap_untrusted_tool_output(value) || value

    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      {:error, _reason} -> decode_exit_code_output(value)
    end
  end

  defp decode_json_or_raw(value) when is_map(value), do: value

  defp unwrap_untrusted_tool_output(value) do
    value = String.trim(value)
    prefix = ~s(<ankole_untrusted_tool_output nonce=")

    with true <- String.starts_with?(value, prefix),
         rest <- String.replace_prefix(value, prefix, ""),
         [nonce, body_with_suffix] <- String.split(rest, ~s(">\n), parts: 2),
         suffix <- ~s(\n</ankole_untrusted_tool_output nonce="#{nonce}">),
         true <- String.ends_with?(body_with_suffix, suffix) do
      String.replace_suffix(body_with_suffix, suffix, "")
    else
      _not_wrapped -> nil
    end
  end

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
          ["background_id", background_id] -> Map.put(acc, "backgroundId", background_id)
          ["status", status] -> Map.put(acc, "status", status)
          ["exit_code", exit_code] -> Map.put(acc, "exitCode", String.to_integer(exit_code))
          _other -> acc
        end
      end)

    case details do
      map when map_size(map) > 0 -> Map.put(details, "raw", value)
      _empty -> %{"raw" => value}
    end
  end

  # -- misc ---------------------------------------------------------------------

  def lark_bot_mention(open_id \\ "ou_bot", key \\ "@_user_1", name \\ "Lark Chaos Bot"),
    do: %{"key" => key, "name" => name, "id" => %{"open_id" => open_id}}

  def openrouter_api_key! do
    System.get_env("OPENROUTER_API_KEY") ||
      System.get_env("OPEN_ROUTER_API_KEY") ||
      flunk("OPENROUTER_API_KEY or OPEN_ROUTER_API_KEY is required for real Lark LLM e2e")
  end

  def unique_worker_auth_key, do: "lark-e2e-" <> Ecto.UUID.generate()

  defp maybe_put_config(map, _key, nil), do: map
  defp maybe_put_config(map, _key, ""), do: map
  defp maybe_put_config(map, key, value), do: Map.put(map, key, value)
end
