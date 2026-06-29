defmodule Ankole.LarkAgentDockerWorkerChaosE2ETest do
  use Ankole.DataCase, async: false

  import Ankole.ActorRuntimeWorkerE2E.DockerWorker

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [deadline: 1, wait_for_worker_projection: 3]

  import Ankole.LarkAgentChaos.E2E.Harness,
    only: [
      dispatch_and_assert_lark_file_outbox: 2,
      dispatch_and_assert_lark_outbox: 4,
      dispatcher_for: 3,
      dispatcher_for: 4,
      openrouter_api_key!: 0,
      safe_stop_router: 0,
      setup_lark_domain!: 1,
      setup_lark_secondary_domain!: 1,
      setup_lark_real_llm_domain!: 1,
      start_ai_gateway_test_http_server!: 0,
      start_fake_llm_server!: 0,
      unique_worker_auth_key: 0
    ]

  import Ankole.LarkAgentChaos.E2E.ComputerStateScenarios
  import Ankole.LarkAgentChaos.E2E.IngressScenarios
  import Ankole.LarkAgentChaos.E2E.LifecycleScenarios
  import Ankole.LarkAgentChaos.E2E.RealLLMScenarios
  import Ankole.LarkAgentChaos.E2E.ScheduleAndToolScenarios
  import Ankole.LarkAgentChaos.E2E.SkillScenarios

  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.LarkAgentChaos.FakeLarkOutbox
  alias Ankole.LarkAgentChaos.FakeOpenAIState

  @tag timeout: 180_000
  @tag ownership_timeout: 180_000
  test "fake Feishu WS ingress drives the real Docker worker and Lark outbox shape" do
    assert_docker_image!()
    assert {:ok, _state} = FakeOpenAIState.start_link(self())
    FakeLarkOutbox.put_owner(self())

    fake_llm_port = start_fake_llm_server!()

    %{
      agent: agent,
      primary_binding: primary_binding,
      record_binding: record_binding,
      ambient_binding: ambient_binding
    } = setup_lark_domain!(fake_llm_port)

    %{agent: secondary_agent, primary_binding: secondary_binding} =
      setup_lark_secondary_domain!(fake_llm_port)

    worker_id = "lark-chaos-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> safe_stop_router() end)
    start_ai_gateway_test_http_server!()

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline(90_000))

    primary_dispatcher = dispatcher_for(agent, primary_binding, "addressed_only")
    record_dispatcher = dispatcher_for(agent, record_binding, "observe_all")
    ambient_dispatcher = dispatcher_for(agent, ambient_binding, "may_intervene")

    primary_multi_dispatcher =
      dispatcher_for(agent, primary_binding, "addressed_only",
        bot_open_id: "ou_lark_bot_a",
        user_name: "Agent A"
      )

    secondary_multi_dispatcher =
      dispatcher_for(secondary_agent, secondary_binding, "addressed_only",
        bot_open_id: "ou_lark_bot_b",
        user_name: "Agent B"
      )

    run_lark_adapter_guardrails(primary_dispatcher)
    run_unaddressed_ignore_guardrail(agent.uid, primary_dispatcher)
    run_observe_all_record_only_projection(agent.uid, record_dispatcher)

    direct_turn = run_direct_duplicate_and_llm_retry(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(direct_turn, "CHAOS_DIRECT_OK", :reply, "om_direct_1")

    isolation_turn = run_channel_session_isolation(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      isolation_turn,
      "CHAOS_GROUP_ISOLATION_OK",
      :reply,
      "om_group_isolation_check_1"
    )

    run_multi_agent_mention_isolation(
      agent.uid,
      primary_multi_dispatcher,
      secondary_agent.uid,
      secondary_multi_dispatcher,
      container
    )

    run_followup_queue(agent.uid, primary_dispatcher, container)
    run_recalled_followup_queue(agent.uid, primary_dispatcher, container)

    retry_turn = run_retry_command(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(retry_turn, "CHAOS_DIRECT_OK", :reply, "om_retry_1")

    compress_turn =
      run_compress_command(agent.uid, primary_dispatcher, container, direct_turn.conversation_id)

    dispatch_and_assert_lark_outbox(
      compress_turn,
      "Conversation compressed.",
      :reply,
      "om_compress_1"
    )

    checkback_turn = run_checkback_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      checkback_turn,
      "CHAOS_CHECKBACK_OK",
      :reply,
      "om_checkback_tool_1"
    )

    checkback_wake_turn = run_checkback_fire(agent.uid, container)

    dispatch_and_assert_lark_outbox(
      checkback_wake_turn,
      "CHAOS_CHECKBACK_WAKE_OK",
      :reply,
      "om_checkback_tool_1"
    )

    cron_turn = run_cron_tool_loop(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(cron_turn, "CHAOS_CRON_OK", :reply, "om_cron_tool_1")

    cron_fire_turn = run_cron_fire(agent.uid, container)

    dispatch_and_assert_lark_outbox(
      cron_fire_turn,
      "CHAOS_CRON_WAKE_OK",
      :post,
      "oc_chaos_schedule"
    )

    attachment_turn = run_file_attachment_roundtrip(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(attachment_turn, "CHAOS_GENERIC_OK", :reply, "om_file_1")

    reply_attachment_turn =
      run_reply_attachment_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_file_outbox(reply_attachment_turn, "om_reply_attachment_1")

    todo_turn = run_todo_tool_loop(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(todo_turn, "CHAOS_TODO_OK", :reply, "om_todo_tool_1")

    browser_turn = run_browser_doctor_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      browser_turn,
      "CHAOS_BROWSER_DOCTOR_OK",
      :reply,
      "om_browser_doctor_1"
    )

    background_turn = run_background_command_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      background_turn,
      "CHAOS_BACKGROUND_COMMAND_OK",
      :reply,
      "om_background_command_1"
    )

    background_lifecycle_turn =
      run_background_command_lifecycle(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      background_lifecycle_turn,
      "CHAOS_BACKGROUND_LIFECYCLE_OK",
      :reply,
      "om_background_lifecycle_1"
    )

    terminal_turn = run_interactive_terminal_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      terminal_turn,
      "CHAOS_INTERACTIVE_TERMINAL_OK",
      :reply,
      "om_interactive_terminal_1"
    )

    terminal_persist_turn =
      run_interactive_terminal_persistence(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      terminal_persist_turn,
      "CHAOS_TERMINAL_PERSIST_READ_OK",
      :reply,
      "om_terminal_persist_read_1"
    )

    browser_open_turn = run_browser_open_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      browser_open_turn,
      "CHAOS_BROWSER_OPEN_OK",
      :reply,
      "om_browser_open_1"
    )

    browser_run_turn = run_browser_run_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      browser_run_turn,
      "CHAOS_BROWSER_RUN_OK",
      :reply,
      "om_browser_run_1"
    )

    browser_extract_turn = run_browser_extract_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      browser_extract_turn,
      "CHAOS_BROWSER_EXTRACT_OK",
      :reply,
      "om_browser_extract_1"
    )

    skill_view_turn = run_skill_view_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      skill_view_turn,
      "CHAOS_SKILL_VIEW_OK",
      :reply,
      "om_skill_view_1"
    )

    all_skill_views_turn = run_all_builtin_skill_views(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      all_skill_views_turn,
      "CHAOS_SKILL_VIEW_ALL_OK",
      :reply,
      "om_skill_view_all_1"
    )

    skill_append_turn = run_skill_append_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      skill_append_turn,
      "CHAOS_SKILL_APPEND_OK",
      :reply,
      "om_skill_append_1"
    )

    disabled_skill_turn = run_disabled_skill_guardrail(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      disabled_skill_turn,
      "CHAOS_SKILL_DISABLED_OK",
      :reply,
      "om_skill_disabled_1"
    )

    read_file_turn = run_read_file_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      read_file_turn,
      "CHAOS_READ_FILE_OK",
      :reply,
      "om_read_file_1"
    )

    patch_turn = run_patch_tool_loop(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      patch_turn,
      "CHAOS_PATCH_TOOL_OK",
      :reply,
      "om_patch_tool_1"
    )

    workspace_read_turn = run_workspace_file_persistence(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      workspace_read_turn,
      "CHAOS_WORKSPACE_READ_OK",
      :reply,
      "om_workspace_read_1"
    )

    malformed_turn = run_malformed_stream_failure(agent.uid, primary_dispatcher, container)
    assert malformed_turn.status == "failed"

    recalled_turn =
      run_recall_during_generation(agent.uid, primary_dispatcher, worker_id, container)

    assert recalled_turn.status == "cancelled"

    stopped_turn = run_stop_command_abort(agent.uid, primary_dispatcher, worker_id, container)
    assert stopped_turn.status == "cancelled"

    run_new_during_generation(agent.uid, primary_dispatcher, worker_id, container)

    steer_turn = run_steer_during_tool_boundary(agent.uid, primary_dispatcher, container)
    dispatch_and_assert_lark_outbox(steer_turn, "CHAOS_STEERED_OK", :reply, "om_steer_tool_1")

    idle_steer_turn = run_idle_steer_generation(agent.uid, primary_dispatcher, container)

    dispatch_and_assert_lark_outbox(
      idle_steer_turn,
      "CHAOS_IDLE_STEER_OK",
      :reply,
      "om_idle_steer_1"
    )

    silent_ambient_turn = run_ambient_silent_batch(agent.uid, ambient_dispatcher, container)
    assert silent_ambient_turn.status == "succeeded"

    ambient_turn = run_ambient_intervention(agent.uid, ambient_dispatcher, container)
    dispatch_and_assert_lark_outbox(ambient_turn, "CHAOS_AMBIENT_OK", :post, "oc_chaos_ambient")

    run_recalled_entry_lifecycle(agent.uid, primary_dispatcher, direct_turn.conversation_id)

    run_old_conversation_recall_after_new(agent.uid, primary_dispatcher, container)

    run_daily_session_reset(agent.uid, primary_dispatcher, container)

    run_new_command(agent.uid, primary_dispatcher, direct_turn.conversation_id)

    counters = FakeOpenAIState.counters()
    assert counters[:direct] >= 2
    assert counters[:dm_isolation_seed] == 1
    assert counters[:group_isolation_check] == 1
    assert counters[:followup_slow] == 1
    assert counters[:followup_second] == 1
    assert counters[:followup_recall_slow] == 1
    assert Map.get(counters, :recalled_followup, 0) == 0
    assert counters[:old_recall] == 1
    assert counters[:after_new_recall] == 1
    assert counters[:reply_attachment] == 3
    assert counters[:todo_tool] == 3
    assert counters[:browser_doctor_tool] == 2
    assert counters[:background_command_tool] == 2
    assert counters[:background_lifecycle_tool] == 4
    assert counters[:interactive_terminal_tool] == 5
    assert counters[:terminal_persist_start_tool] == 3
    assert counters[:terminal_persist_read_tool] == 4
    assert counters[:browser_open_tool] == 2
    assert counters[:browser_run_tool] == 2
    assert counters[:browser_extract_tool] == 2
    assert counters[:skill_view_tool] == 2
    assert counters[:skill_view_all_tool] == 4
    assert counters[:skill_append_tool] == 2
    assert counters[:skill_disabled_tool] == 2
    assert counters[:read_file_tool] == 3
    assert counters[:patch_tool] == 4
    assert counters[:workspace_write_tool] == 2
    assert counters[:workspace_read_tool] == 2
    assert counters[:checkback_tool] == 2
    assert counters[:checkback_wakeup] == 1
    assert counters[:cron_tool] == 2
    assert counters[:cron_wakeup] == 1
    assert counters[:slow_recall_stream] == 1
    assert counters[:slow_stop_stream] == 1
    assert counters[:slow_new_stream] == 1
    assert counters[:new_after] == 1
    assert counters[:steer_tool] == 1
    assert counters[:steered_reply] == 1
    assert counters[:idle_steer] == 1
    assert Map.get(counters, :malformed_stream, 0) >= 1
    assert counters[:ambient_noop_decision] == 1
    assert counters[:ambient_decision] == 1
    assert counters[:ambient_reply] == 1
  end

  @tag timeout: 300_000
  @tag ownership_timeout: 300_000
  @tag :real_llm
  test "fake Feishu WS ingress drives the real Docker worker through OpenRouter" do
    assert_docker_image!()
    FakeLarkOutbox.put_owner(self())

    %{agent: agent, primary_binding: primary_binding} =
      setup_lark_real_llm_domain!(openrouter_api_key!())

    worker_id = "lark-real-llm-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> safe_stop_router() end)
    start_ai_gateway_test_http_server!()

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline(90_000))

    dispatcher = dispatcher_for(agent, primary_binding, "addressed_only")

    direct_turn = run_real_lark_direct_turn(agent.uid, dispatcher, container)
    dispatch_and_assert_lark_outbox(direct_turn, "ANKOLE_LARK_REAL_OK", :reply, "om_real_1")

    skill_turn = run_real_lark_skill_tool_loop(agent.uid, dispatcher, container)

    dispatch_and_assert_lark_outbox(
      skill_turn,
      "ANKOLE_LARK_REAL_SKILL_OK",
      :reply,
      "om_real_skill_1"
    )
  end
end
