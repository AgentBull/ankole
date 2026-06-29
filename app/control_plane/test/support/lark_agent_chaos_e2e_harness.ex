defmodule Ankole.LarkAgentChaos.E2E.Harness do
  @moduledoc """
  Shared setup and assertions for Lark chaos e2e tests.

  Fake Feishu frames and fake provider responses make the scenarios
  deterministic. The worker under test is still the real Agent Computer process
  running in Docker.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.ReadyInputProcessor
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.LarkAgentChaos.FakeLarkOutbox
  alias Ankole.LarkAgentChaos.FakeOpenAIPlug
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Plugins.LarkAdapter.Dispatcher, as: LarkDispatcher
  alias Ankole.Plugins.LarkAdapter.Inbound, as: LarkInbound
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @long_lease_seconds 604_800

  @doc "Returns the fixed timestamp used to keep chaos scenario ordering stable."
  def base_time, do: @base_time

  @doc "Returns the long lease used by slow worker e2e turns."
  def long_lease_seconds, do: @long_lease_seconds

  def start_fake_llm_server! do
    server =
      start_supervised!(
        {Bandit, plug: FakeOpenAIPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  def setup_lark_domain!(fake_llm_port) do
    uid =
      "agent-lark-chaos-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "fake-openrouter-chaos-#{Ecto.UUID.generate()}"
    assert {:ok, %{skills: _count}} = Library.sync_builtin_skills(force: true)

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
               uid: uid,
               display_name: "Lark Chaos Agent",
               role: "Reliability test agent"
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai-compatible",
               credential: "sk-fake-chaos",
               # Provider upstream calls originate from host-side AIGateway, not
               # from the Docker worker, so localhost is correct here.
               base_url: "http://127.0.0.1:#{fake_llm_port}",
               connection_options: %{
                 "include_usage" => true,
                 "supports_structured_outputs" => true
               }
             })

    for {profile, model} <- [{"primary", "fake-main-chaos"}, {"light", "fake-light-chaos"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options: %{}
               })
    end

    assert {:ok, primary_binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-chaos-primary",
               adapter: "lark",
               config_ref: "app-config://signals_gateway.lark.bindings.lark-chaos-primary",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    assert {:ok, record_binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-chaos-record",
               adapter: "lark",
               config_ref: "app-config://signals_gateway.lark.bindings.lark-chaos-record",
               filters: %{},
               unaddressed_group_message_policy: :record_only
             })

    assert {:ok, ambient_binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-chaos-ambient",
               adapter: "lark",
               config_ref: "app-config://signals_gateway.lark.bindings.lark-chaos-ambient",
               filters: %{},
               unaddressed_group_message_policy: :may_intervene
             })

    %{
      agent: agent,
      primary_binding: primary_binding,
      record_binding: record_binding,
      ambient_binding: ambient_binding
    }
  end

  def setup_lark_secondary_domain!(fake_llm_port) do
    uid =
      "agent-lark-chaos-secondary-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    provider_id = "fake-chaos2-#{Ecto.UUID.generate()}"

    assert {:ok, %{principal: agent}} =
             Principals.create_agent(%{
               uid: uid,
               display_name: "Lark Chaos Secondary Agent",
               role: "Second reliability test agent"
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai-compatible",
               credential: "sk-fake-chaos-secondary",
               base_url: "http://127.0.0.1:#{fake_llm_port}",
               connection_options: %{
                 "include_usage" => true,
                 "supports_structured_outputs" => true
               }
             })

    for {profile, model} <- [{"primary", "fake-main-chaos"}, {"light", "fake-light-chaos"}] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options: %{}
               })
    end

    assert {:ok, primary_binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-chaos-secondary",
               adapter: "lark",
               config_ref: "app-config://signals_gateway.lark.bindings.lark-chaos-secondary",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    %{agent: agent, primary_binding: primary_binding}
  end

  def setup_lark_real_llm_domain!(openrouter_api_key) do
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
               credential: openrouter_api_key,
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    for {profile, model} <- [
          {"primary", "openai/gpt-5.4-nano"},
          {"light", "openai/gpt-5.4-nano"}
        ] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: model,
                 provider_options: %{"reasoning" => %{"effort" => "minimal", "exclude" => true}}
               })
    end

    assert {:ok, primary_binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "lark-real-llm-primary",
               adapter: "lark",
               config_ref: "app-config://signals_gateway.lark.bindings.lark-real-llm-primary",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    %{agent: agent, primary_binding: primary_binding}
  end

  def dispatcher_for(agent, binding, group_message_mode, opts \\ []) do
    config_input =
      %{
        "appId" => Keyword.get(opts, :app_id, "cli_chaos_lark"),
        "appSecret" => "secret-chaos",
        "domain" => "feishu",
        "platformSubjectNamespace" => "lark-chaos",
        "userName" => Keyword.get(opts, :user_name, "Lark Chaos Bot"),
        "group_message_mode" => group_message_mode
      }
      |> maybe_put_config("botOpenId", Keyword.get(opts, :bot_open_id))
      |> maybe_put_config("botUserId", Keyword.get(opts, :bot_user_id))

    {:ok, config} =
      LarkConfig.validate_chat_config(config_input)

    context =
      AdapterContext.new(
        agent_uid: agent.uid,
        binding_name: binding.name,
        adapter: "lark",
        user_name: Map.fetch!(config, "userName")
      )

    consumer = LarkInbound.chat_consumer(context, config)
    LarkDispatcher.build([consumer])
  end

  def dispatch_and_assert_lark_outbox(turn, expected_text, expected_operation, expected_target) do
    outbox = Repo.get_by!(OutboxEntry, llm_turn_id: turn.id)
    assert outbox.payload["text"] =~ expected_text

    assert [{:ok, %OutboxEntry{status: :succeeded}}] =
             OutboxDispatcher.run_once(
               adapter_resolver: fn _outbox -> {:ok, FakeLarkOutbox} end,
               limit: 20
             )

    outbox_id = outbox.outbound_key
    assert_receive {:fake_lark_outbox_send, ^outbox_id, request, sent_outbox}, 2_000
    assert_lark_request_shape(request, sent_outbox, expected_operation, expected_target)
    assert request.body.msg_type == "text"
    assert request.body.content =~ expected_text
  end

  def successful_tool_results(tool_results, tool_name) when is_list(tool_results) do
    Enum.filter(tool_results, fn
      %{"tool_name" => ^tool_name, "is_error" => false} -> true
      _result -> false
    end)
  end

  def successful_tool_results(_tool_results, _tool_name), do: []

  def dispatch_and_assert_lark_file_outbox(turn, expected_target) do
    outbox = Repo.get_by!(OutboxEntry, llm_turn_id: turn.id)
    assert outbox.payload["text"] =~ "CHAOS_REPLY_ATTACHMENT_OK"

    assert [
             %{
               "user_files_relative_path" => "reports/chaos-report.txt",
               "name" => "chaos-report.txt"
             }
           ] = outbox.payload["attachments"]

    assert [{:ok, %OutboxEntry{status: :succeeded}}] =
             OutboxDispatcher.run_once(
               adapter_resolver: fn _outbox -> {:ok, FakeLarkOutbox} end,
               limit: 20
             )

    outbox_id = outbox.outbound_key
    assert_receive {:fake_lark_outbox_send, ^outbox_id, request, sent_outbox}, 2_000
    assert_lark_request_shape(request, sent_outbox, :reply, expected_target)
    assert request.body.msg_type == "file"
    assert {:ok, content} = Ankole.JSON.decode(request.body.content)
    assert content["file_key"] =~ "fake_file_"

    assert [
             %{
               "provider_file_key" => provider_file_key,
               "user_files_relative_path" => "reports/chaos-report.txt"
             }
           ] = sent_outbox.payload["attachments"]

    assert provider_file_key == content["file_key"]
  end

  def assert_lark_request_shape(request, sent_outbox, :reply, source_provider_entry_id) do
    assert sent_outbox.source_provider_entry_id == source_provider_entry_id
    assert request.path == "im/v1/messages/:message_id/reply"
    assert request.path_params == %{message_id: source_provider_entry_id}
  end

  def assert_lark_request_shape(request, _sent_outbox, :post, chat_id) do
    assert request.path == "im/v1/messages"
    assert request.query == [receive_id_type: "chat_id"]
    assert request.body.receive_id == chat_id
  end

  def actor_input_by_provider_entry_id!(agent_uid, provider_entry_id) do
    finalize_due_inbound_batches!()

    Repo.get_by!(ActorInput,
      agent_uid: agent_uid,
      provider_entry_id: provider_entry_id
    )
  end

  def finalize_due_inbound_batches! do
    assert {:ok, _results} =
             SignalsGateway.finalize_due_inbound_batches(
               now: DateTime.utc_now(:microsecond) |> DateTime.add(120, :second),
               limit: 500
             )
  end

  def process_ready_input_for_actor!(%ActorInput{} = input, now) do
    ReadyInputProcessor.process_ready_inputs_for_actor(
      %{agent_uid: input.agent_uid, session_id: input.session_id},
      now: now,
      lease_seconds: @long_lease_seconds
    )
  end

  def start_ai_gateway_test_http_server! do
    server =
      start_supervised!(
        {Bandit,
         plug: AnkoleWeb.Endpoint, scheme: :http, ip: {0, 0, 0, 0}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    old_env = Application.fetch_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)

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

  def lark_bot_mention(open_id \\ "ou_bot", key \\ "_user_1", name \\ "Lark Chaos Bot"),
    do: %{"key" => key, "name" => name, "id" => %{"open_id" => open_id}}

  def openrouter_api_key! do
    System.get_env("OPENROUTER_API_KEY") ||
      System.get_env("OPEN_ROUTER_API_KEY") ||
      flunk("OPENROUTER_API_KEY or OPEN_ROUTER_API_KEY is required for real Lark LLM e2e")
  end

  def unique_worker_auth_key, do: "lark-chaos-" <> Ecto.UUID.generate()

  defp maybe_put_config(map, _key, nil), do: map
  defp maybe_put_config(map, _key, ""), do: map
  defp maybe_put_config(map, key, value), do: Map.put(map, key, value)
end
