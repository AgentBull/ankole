defmodule Ankole.E2E.WorkerComputerE2ETest do
  @moduledoc """
  Worker admission plus the computer tool surface: command, todo, browser,
  interactive terminal, read_file, patch, skills, attachments, and workspace
  persistence — all through the real Docker worker.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.DockerWorker
  import Ankole.E2E.Harness
  import Ankole.E2E.Scenarios.ComputerState

  import Ankole.E2E.Scenarios.ScheduleAndTool,
    except: [
      run_checkback_tool_loop: 1,
      run_checkback_fire: 1,
      run_cron_tool_loop: 1,
      run_cron_fire: 1
    ]

  import Ankole.E2E.Scenarios.Skill

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_for_worker_projection: 3]

  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo

  @tag timeout: 45_000
  @tag :worker_bootstrap_contract
  test "Docker image worker connects to RuntimeFabric and is admitted" do
    assert_docker_image!()

    worker_id = "docker-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> safe_stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline(30_000))

    assert :ok = assert_launch_contract!(container)
  end

  @tag timeout: 30_000
  test "Docker image worker with the wrong global worker auth key is not admitted" do
    assert_docker_image!()

    worker_id = "docker-rejected-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> safe_stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: "wrong-" <> worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    refute_worker_projection_until(
      worker_id,
      container,
      System.monotonic_time(:millisecond) + 1_500
    )

    assert Repo.get_by(AgentComputerWorker, worker_id: worker_id) == nil
  end

  test "Docker image worker fails fast with structured error when required env is missing" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"WORKER_ID", "worker-missing-env"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "RUNTIME_FABRIC_URL is required"
  end

  test "Docker image worker rejects actor-specific startup env" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"RUNTIME_FABRIC_URL", "tcp://:unused-test-secret@host.docker.internal:1"},
               {"WORKER_ID", "worker-actor-env"},
               {"ANKOLE_AGENT_UID", "agent-1"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_AGENT_UID must not be set on an agent computer worker"
  end

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  test "computer tools, skills, attachments, and workspace persistence" do
    ctx = start_worker_e2e_stack!()

    attachment = run_file_attachment_roundtrip(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      attachment.reply,
      "CHAOS_GENERIC_OK",
      :reply,
      "om_file_1"
    )

    reply_attachment = run_reply_attachment_tool_loop(ctx)

    dispatch_and_assert_lark_file_outbox(
      ctx.fake_feishu,
      reply_attachment.outbox,
      "om_reply_attachment_1"
    )

    todo = run_todo_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      todo.reply,
      "CHAOS_TODO_OK",
      :reply,
      "om_todo_tool_1"
    )

    background = run_background_command_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      background.reply,
      "CHAOS_BACKGROUND_COMMAND_OK",
      :reply,
      "om_background_command_1"
    )

    background_lifecycle = run_background_command_lifecycle(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      background_lifecycle.reply,
      "CHAOS_BACKGROUND_LIFECYCLE_OK",
      :reply,
      "om_background_lifecycle_1"
    )

    terminal = run_interactive_terminal_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      terminal.reply,
      "CHAOS_INTERACTIVE_TERMINAL_OK",
      :reply,
      "om_interactive_terminal_1"
    )

    terminal_persist = run_interactive_terminal_persistence(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      terminal_persist.reply,
      "CHAOS_TERMINAL_PERSIST_READ_OK",
      :reply,
      "om_terminal_persist_read_1"
    )

    browser_open = run_browser_open_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      browser_open.reply,
      "CHAOS_BROWSER_OPEN_OK",
      :reply,
      "om_browser_open_1"
    )

    browser_run = run_browser_run_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      browser_run.reply,
      "CHAOS_BROWSER_RUN_OK",
      :reply,
      "om_browser_run_1"
    )

    browser_extract = run_browser_extract_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      browser_extract.reply,
      "CHAOS_BROWSER_EXTRACT_OK",
      :reply,
      "om_browser_extract_1"
    )

    skill_view = run_skill_view_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      skill_view.reply,
      "CHAOS_SKILL_VIEW_OK",
      :reply,
      "om_skill_view_1"
    )

    all_skill_views = run_all_builtin_skill_views(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      all_skill_views.reply,
      "CHAOS_SKILL_VIEW_ALL_OK",
      :reply,
      "om_skill_view_all_1"
    )

    skill_append = run_skill_append_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      skill_append.reply,
      "CHAOS_SKILL_APPEND_OK",
      :reply,
      "om_skill_append_1"
    )

    disabled_skill = run_disabled_skill_guardrail(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      disabled_skill.reply,
      "CHAOS_SKILL_DISABLED_OK",
      :reply,
      "om_skill_disabled_1"
    )

    read_file = run_read_file_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      read_file.reply,
      "CHAOS_READ_FILE_OK",
      :reply,
      "om_read_file_1"
    )

    patch = run_patch_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      patch.reply,
      "CHAOS_PATCH_TOOL_OK",
      :reply,
      "om_patch_tool_1"
    )

    workspace = run_workspace_file_persistence(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      workspace.reply,
      "CHAOS_WORKSPACE_READ_OK",
      :reply,
      "om_workspace_read_1"
    )

    counters = FakeOpenAIState.counters()
    assert counters[:generic] == 1
    assert counters[:reply_attachment] == 3
    assert counters[:todo_tool] == 3
    assert counters[:background_command_tool] == 2
    assert counters[:background_lifecycle_tool] == 4
    assert counters[:interactive_terminal_tool] == 5
    assert counters[:terminal_persist_start_tool] == 3
    assert counters[:terminal_persist_read_tool] == 4
    assert counters[:browser_open_tool] == 2
    assert counters[:browser_run_tool] == 2
    assert counters[:browser_extract_tool] == 2
    assert counters[:skill_view_tool] == 2
    assert counters[:skill_view_all_tool] == 6
    assert counters[:skill_append_tool] == 2
    assert counters[:skill_disabled_tool] == 2
    assert counters[:read_file_tool] == 3
    assert counters[:patch_tool] == 4
    assert counters[:workspace_write_tool] == 2
    assert counters[:workspace_read_tool] == 2
  end

  @tag :installed_skill_registry
  @tag timeout: 240_000
  @tag ownership_timeout: 240_000
  test "installed skill registry syncs from the real Docker worker filesystem" do
    ctx = start_worker_e2e_stack!(worker_prefix: "installed-skill-e2e")

    installed_skill = run_installed_skill_registry_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      installed_skill.reply,
      "CHAOS_INSTALLED_SKILL_OK",
      :reply,
      "om_installed_skill_1"
    )

    assert_lark_final_reply(
      ctx.fake_feishu,
      installed_skill.deleted_reply,
      "CHAOS_INSTALLED_SKILL_DELETED_OK",
      :reply,
      "om_installed_skill_deleted_1"
    )

    counters = FakeOpenAIState.counters()
    assert counters[:installed_skill_tool] == 2
    assert counters[:installed_skill_deleted_tool] == 2
  end

  defp refute_worker_projection_until(worker_id, process, deadline) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{} = worker ->
        flunk("worker should not have been admitted: #{inspect(worker)}")

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          :ok
        else
          port = process_port(process)

          receive do
            {^port, {:exit_status, _status}} ->
              :ok

            {^port, {:data, _data}} ->
              refute_worker_projection_until(worker_id, process, deadline)
          after
            50 ->
              refute_worker_projection_until(worker_id, process, deadline)
          end
        end
    end
  end

  defp process_port(%{port: port}), do: port
  defp process_port(port) when is_port(port), do: port
end
