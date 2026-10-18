defmodule Ankole.E2E.WorkerComputerE2ETest do
  @moduledoc """
  Worker admission, the instance sweep of the Docker provider, and the main-agent
  computer tool surface: one-shot command, todo, read_file, patch, skills,
  attachments, and workspace persistence — all through the real Docker worker.
  """

  use Ankole.DataCase, async: false

  import Ankole.E2E.DockerWorker
  import Ankole.E2E.Harness

  import Ankole.E2E.Scenarios.ScheduleAndTool,
    except: [
      run_checkback_tool_loop: 1,
      run_checkback_fire: 2,
      run_cron_tool_loop: 1,
      run_cron_fire: 2
    ]

  import Ankole.E2E.Scenarios.Skill

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.AgentWorkers.SweepJob
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo

  @tag timeout: 180_000
  @tag :worker_bootstrap_contract
  test "the control plane creates an Agent's Worker in Docker and admits it" do
    assert_docker_image!()
    %{principal: agent} = create_e2e_agent!(worker_agent_attrs())

    %{container: container} = start_worker!([agent.uid])

    assert %AgentWorker{state: "ready", generation: generation, transport_route: route} =
             Repo.get!(AgentWorker, agent.uid)

    assert is_binary(generation) and is_binary(route)
    assert :ok = assert_launch_contract!(agent.uid)

    assert exec!(container, ["sh", "-c", "test -w /agents/#{agent.uid} && echo writable"]) =~
             "writable"
  end

  @tag timeout: 180_000
  @tag :worker_resume_connection
  test "the same Worker process reconnects after its event loop resumes" do
    assert_docker_image!()
    %{principal: agent} = create_e2e_agent!(worker_agent_attrs())
    %{container: container} = start_worker!([agent.uid])
    admitted = Repo.get!(AgentWorker, agent.uid)
    name = container_name(agent.uid)
    docker = System.find_executable("docker")

    # The idle-pause contract applies after startup. Admission can precede
    # browser startup; an RPC reply proves that the main loop is running.
    assert {:error, %{"code" => "unknown_rpc_method"}} =
             Ankole.AgentWorkers.WorkerRoute.request_rpc(
               %{worker_id: agent.uid, transport_route: admitted.transport_route},
               "worker.no_such_method",
               <<>>,
               timeout_ms: 10_000
             )

    exec!(container, ["sh", "-ec", "printf kept > /workspace/resume-marker"])

    # Docker freeze is a process-resume fault injection. Docker does not
    # expose memory hibernation as a Worker provider capability.
    assert {_output, 0} = System.cmd(docker, ["pause", name], stderr_to_stdout: true)

    try do
      Process.sleep(35_000)
    after
      assert {_output, 0} = System.cmd(docker, ["unpause", name], stderr_to_stdout: true)
    end

    assert {:ok, resumed} =
             wait_until(deadline(30_000), fn ->
               worker = Repo.get!(AgentWorker, agent.uid)

               (worker.state == "ready" and worker.transport_route != admitted.transport_route) &&
                 worker
             end)

    assert resumed.generation == admitted.generation
    assert resumed.incarnation_id == admitted.incarnation_id, logs(container)
    assert logs(container) =~ "worker.instance_resumed"
    assert exec!(container, ["cat", "/workspace/resume-marker"]) == "kept"

    assert {:error, %{"code" => "unknown_rpc_method"}} =
             Ankole.AgentWorkers.WorkerRoute.request_rpc(
               %{worker_id: agent.uid, transport_route: resumed.transport_route},
               "worker.no_such_method",
               <<>>,
               timeout_ms: 10_000
             )
  end

  @tag timeout: 180_000
  @tag :worker_rejected_credential
  test "a Worker with a revoked credential cannot join or remove the admitted Worker's run files" do
    assert_docker_image!()
    %{principal: agent} = create_e2e_agent!(worker_agent_attrs())
    %{endpoint: endpoint} = start_worker!([agent.uid])
    admitted = Repo.get!(AgentWorker, agent.uid)
    # A real RPC reply proves that startup cleanup finished before the marker.
    assert {:error, %{"code" => "unknown_rpc_method"}} =
             Ankole.AgentWorkers.WorkerRoute.request_rpc(
               %{worker_id: agent.uid, transport_route: admitted.transport_route},
               "worker.no_such_method",
               <<>>,
               timeout_ms: 10_000
             )

    home = storage_volumes(agent.uid).home
    marker = "/workspace/.ankole/automation-runs/active/keep"

    exec!(container(agent.uid), [
      "sh",
      "-ec",
      "mkdir -p /workspace/.ankole/automation-runs/active; printf kept > #{marker}"
    ])

    {:ok, provider} = Providers.load(admitted.provider_id)

    env =
      WorkerBootstrap.agent_worker_spec(
        provider,
        agent.uid,
        admitted.generation,
        "not-the-generation-credential"
      ).env
      |> Map.put("ANKOLE_RUNTIME_FABRIC_ENDPOINT", endpoint)
      |> Enum.to_list()

    unmanaged = start_unmanaged_worker!(env, home_volume: home)

    # The socket refuses the connection; the container keeps retrying.
    assert {:ok, _logs} =
             wait_until(deadline(60_000), fn ->
               logs = logs(unmanaged)
               String.contains?(logs, "worker.fabric_socket_error") && logs
             end)

    assert %AgentWorker{state: "ready", transport_route: route, generation: generation} =
             Repo.get!(AgentWorker, agent.uid)

    assert route == admitted.transport_route
    assert generation == admitted.generation
    assert exec!(container(agent.uid), ["cat", marker]) == "kept"
  end

  @tag timeout: 180_000
  test "the object sweep deletes a Worker container without a row and keeps other installations" do
    assert_docker_image!()
    installation = install_provider!("ws://host.docker.internal:9/runtime-fabric/worker")
    foreign_installation = installation <> "other"

    orphan = create_labeled_container!(installation, "agent-e2e-orphan", "orphan1")
    foreign = create_labeled_container!(foreign_installation, "agent-e2e-orphan", "orphan1")

    other_provider =
      create_labeled_container!(installation, "agent-e2e-foreign", "orphan1", "outside")

    assert :ok = SweepJob.perform(%Oban.Job{args: %{"objects" => true}})

    assert container_info(orphan) == nil
    assert %{status: "created"} = container_info(foreign)
    assert %{status: "created"} = container_info(other_provider)
  end

  test "Docker image worker fails fast with structured error when required env is missing" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"WORKER_ID", "worker-missing-env"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_RUNTIME_FABRIC_ENDPOINT is required"
  end

  test "Docker image worker rejects a control-plane database URL" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"ANKOLE_RUNTIME_FABRIC_ENDPOINT",
                "ws://host.docker.internal:1/runtime-fabric/worker"},
               {"ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY", "unused-test-secret"},
               {"WORKER_ID", "worker-database-env"},
               {"DATABASE_URL", "ecto://fixture:unused@127.0.0.1/forbidden_worker_database"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "DATABASE_URL must not be set on an agent computer worker"
  end

  @tag :post_file_attachment
  @tag timeout: 180_000
  test "a Lark rich-post file reaches the Docker Worker and the model request" do
    ctx = start_worker_e2e_stack!()
    result = run_file_attachment_roundtrip(ctx, "post")
    path = result.attachment["path"]

    # The adapter stored the bytes in the file service and the gateway named
    # them in the Agent's drive; the model sees the drive path.
    assert {:ok, _file, "CHAOS_INBOUND_FILE_BYTES deck"} = Ankole.Files.read(ctx.agent.uid, path)

    assert Enum.any?(FakeOpenAIState.requests(), fn entry ->
             request = Ankole.JSON.encode!(entry.request)

             String.contains?(request, "deck.pdf") and String.contains?(request, path) and
               String.contains?(request, "ankole-files get")
           end)

    assert_lark_final_reply(
      ctx.fake_feishu,
      result.reply,
      "CHAOS_GENERIC_OK",
      :reply,
      "om_file_1"
    )
  end

  @tag :worker_computer_path
  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  test "computer tools, skills, attachments, and workspace persistence" do
    ctx = start_worker_e2e_stack!()

    %AgentWorker{state: "ready", generation: generation, incarnation_id: incarnation_id} =
      Repo.get!(AgentWorker, ctx.agent.uid)

    attachment = run_file_attachment_roundtrip(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      attachment.reply,
      "CHAOS_GENERIC_OK",
      :reply,
      "om_file_1"
    )

    todo = run_todo_tool_loop(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      todo.reply,
      "CHAOS_TODO_OK",
      :reply,
      "om_todo_tool_1"
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

    disabled_skill = run_disabled_skill_guardrail(ctx)

    assert_lark_final_reply(
      ctx.fake_feishu,
      disabled_skill.reply,
      "CHAOS_SKILL_DISABLED_OK",
      :reply,
      "om_skill_disabled_1"
    )

    assert %AgentWorker{
             state: "ready",
             generation: ^generation,
             incarnation_id: ^incarnation_id
           } = Repo.get!(AgentWorker, ctx.agent.uid)

    reply_attachment = run_reply_attachment_tool_loop(ctx)

    dispatch_and_assert_lark_file_intent(
      ctx.fake_feishu,
      reply_attachment.intent,
      "om_reply_attachment_1"
    )

    assert Repo.get!(AgentWorker, ctx.agent.uid).state == "ready"

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
    assert counters[:skill_view_tool] == 2
    assert counters[:skill_view_all_tool] == 3
    assert counters[:skill_disabled_tool] == 2
    assert counters[:read_file_tool] == 3
    assert counters[:patch_tool] == 4
    assert counters[:workspace_write_tool] == 2
    # ankole-files get, read_file, then the reply.
    assert counters[:workspace_read_tool] == 3
  end

  @tag :internal_skill_path
  @tag skip: System.get_env("ANKOLE_INTERNAL_SKILLS_ROOT") in [nil, ""]
  @tag timeout: 180_000
  test "an internal Skill directory reaches a reference on the real Worker" do
    ctx = start_worker_e2e_stack!()
    directory = "/repo/internals/skills/twitterapi-io"
    reference = "references/write-operations.md"

    expected =
      File.read!(
        Path.join(System.fetch_env!("ANKOLE_INTERNAL_SKILLS_ROOT"), "twitterapi-io/#{reference}")
      )

    assert exec!(ctx.container, ["cat", "#{directory}/#{reference}"]) == expected

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_internal_skill_path",
               message_id: "om_internal_skill_path",
               chat_id: "oc_internal_skill_path",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_INTERNAL_SKILL. Read twitterapi-io with skill_view, then its write-operations reference with read_file. Reply CHAOS_INTERNAL_SKILL_OK.",
               mentions: [lark_bot_mention()],
               create_time_ms: System.system_time(:millisecond)
             )

    input = signal_by_provider_message_id!(ctx.agent.uid, "om_internal_skill_path")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             Ankole.E2E.WaitHelpers.wait_for_completed_final_reply(
               %{agent_uid: ctx.agent.uid},
               input.id,
               deadline(90_000)
             )

    assert reply.message.text =~ "CHAOS_INTERNAL_SKILL_OK"
    messages = Ankole.E2E.WaitHelpers.ai_messages_for_signal(input.id)
    assert [%{"raw" => skill}] = successful_tool_results(messages, "skill_view")
    assert skill =~ "directory=\"#{directory}\""
    assert skill =~ "references/write-operations.md"
    assert [%{"raw" => read}] = successful_tool_results(messages, "read_file")

    read_lines =
      read
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/^\d+\|/, &1))
      |> Enum.map(&String.replace(&1, ~r/^\d+\|/, ""))

    assert Enum.join(read_lines, "\n") == String.trim_trailing(expected, "\n")
    assert [%{arguments: %{"path" => path}}] = tool_results(messages, "read_file")
    assert path == "#{directory}/#{reference}"
    assert FakeOpenAIState.counters()[:internal_skill_tool] == 3
    assert_signal_completed!(input.id)
  end

  @tag :installed_skill_registry
  @tag timeout: 240_000
  @tag ownership_timeout: 240_000
  test "installed Skill catalog follows the drive used by the real Docker Worker" do
    ctx = start_worker_e2e_stack!()

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

  defp worker_agent_attrs do
    %{
      uid:
        "agent-worker-e2e-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}",
      display_name: "Worker E2E Agent",
      role: "Worker lifecycle test agent"
    }
  end
end
