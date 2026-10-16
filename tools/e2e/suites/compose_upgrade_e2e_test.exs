defmodule Ankole.E2E.ComposeUpgradeTest do
  use ExUnit.Case, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.E2E.ComposeDeployment, as: Compose
  alias Ankole.E2E.FakeOpenAIPlug
  alias Ankole.E2E.FakeOpenAIState

  @moduletag timeout: 600_000
  @moduletag :compose_upgrade

  test "a pooled deployment migrates its Homes and adopts a command after all control-plane processes restart" do
    {old, owner} = Compose.start_legacy!() |> Compose.setup_admin!()
    uid = "compose-upgrade-agent"

    assert %{"agent" => %{"uid" => ^uid}} =
             Compose.api!(old, :post, "/api/v1/agents", %{
               uid: uid,
               display_name: "Upgrade Agent",
               role: "Upgrade test",
               owner_principal_uid: owner
             })

    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               Enum.any?(
                 Compose.api!(old, :get, "/api/v1/agent-computer-workers")["workers"],
                 &(&1["status"] == "ready")
               )
             end)

    # The old Worker writes an unfinished workspace into its pooled Home.
    Compose.compose!(old, [
      "exec",
      "-T",
      "worker",
      "sh",
      "-ec",
      "mkdir -p /agents/#{uid}/sessions/unfinished; chmod 700 /agents/#{uid}; printf legacy-work > /agents/#{uid}/sessions/unfinished/keep"
    ])

    deployment = Compose.upgrade!(old)

    assert %{"agent" => %{"uid" => ^uid, "worker_provider_id" => "docker"}} =
             Compose.api!(deployment, :get, "/api/v1/agents/#{uid}")

    assert {:ok, _state} = FakeOpenAIState.start_link(self())

    server =
      start_supervised!({Bandit, plug: FakeOpenAIPlug, scheme: :http, ip: {0, 0, 0, 0}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Compose.api!(deployment, :put, "/api/v1/site/ai-gateway/providers/compose-model", %{
      provider_kind: "openai_compatible",
      base_url: "http://host.docker.internal:#{port}",
      credential_pool: %{entries: [%{label: "Test", api_key: "compose-test-only"}]}
    })

    for profile <- ["primary", "light"] do
      Compose.api!(deployment, :put, "/api/v1/agents/#{uid}/model-profiles/#{profile}", %{
        provider_id: "compose-model",
        model: "fake-main-chaos",
        context_length: 131_072
      })
    end

    target_conversation_id = Ecto.UUID.generate()

    assert %{"conversation" => %{"id" => ^target_conversation_id}} =
             Compose.api!(deployment, :post, "/.internal-apis/pod/conversations", %{
               conversationID: target_conversation_id,
               agentUID: uid,
               messageID: Ecto.UUID.generate(),
               text: "CHAOS_DIRECT_OK"
             })

    # The fake model answers this ordinary native message without a command.
    # Finish that real first turn before the scheduled command story begins.
    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               detail =
                 Compose.api!(
                   deployment,
                   :get,
                   "/.internal-apis/pod/conversations/#{target_conversation_id}"
                 )

               detail["status"]["state"] == "idle" and
                 Enum.any?(detail["messages"], fn message ->
                   message["authorType"] == "agent" and message["text"] == "CHAOS_DIRECT_OK"
                 end)
             end)

    # Scheduled input alone does not need a Worker. Its command must request
    # the migrated Agent's computer through the production tool path.
    assert %{"cron_schedule" => %{"id" => schedule_id}} =
             Compose.api!(deployment, :post, "/api/v1/agents/#{uid}/cron-schedules", %{
               owner_session_id: "conversation:#{target_conversation_id}",
               name: "read-migrated-work",
               schedule: %{kind: "cron", expression: "* * * * *"},
               timezone: "UTC",
               payload: %{task: "COMPOSE_UPGRADE_READ: read the migrated workspace file."},
               delivery: %{
                 targets: [
                   %{conversation_id: target_conversation_id}
                 ]
               },
               idempotency_key: "compose-upgrade"
             })

    assert {:ok, worker} =
             wait_until(deadline(120_000), fn ->
               Enum.find(
                 Compose.api!(deployment, :get, "/api/v1/agent-workers")["workers"],
                 &(&1["agent_uid"] == uid and &1["state"] == "ready")
               )
             end)

    assert worker["provider_id"] == "docker"

    name =
      Ankole.AgentWorkers.ProviderKind.instance_name(
        deployment.project,
        uid,
        worker["generation"]
      )

    assert {:ok, command_pid} =
             wait_until(deadline(30_000), fn ->
               pid =
                 Compose.docker!([
                   "exec",
                   name,
                   "sh",
                   "-ec",
                   "cat /workspace/sessions/unfinished/read.pid 2>/dev/null || true"
                 ])
                 |> String.trim()

               if pid != "", do: pid
             end)

    read_input = fn ->
      Compose.compose!(deployment, [
        "exec",
        "-T",
        "postgresql",
        "sh",
        "-ec",
        "exec psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" \"$@\"",
        "psql",
        "-Atc",
        "SELECT json_build_object('id', id::text, 'attempt_count', attempt_count) " <>
          "FROM signals WHERE agent_uid = '#{uid}' AND type = 'cron.fire' " <>
          "ORDER BY queue_sequence LIMIT 1"
      ])
      |> Ankole.JSON.decode!()
    end

    input_before = read_input.()
    assert input_before["attempt_count"] == 1

    # This deployment has one control-plane container. Stop every BEAM process
    # before restarting PostgreSQL; only committed facts and the Worker survive.
    Compose.compose!(deployment, ["stop", "control-plane"])
    stopped = String.trim(Compose.compose!(deployment, ["ps", "-aq", "control-plane"]))

    assert String.trim(Compose.docker!(["inspect", "--format", "{{.State.Running}}", stopped])) ==
             "false"

    assert read_input.()["attempt_count"] == 0
    Compose.compose!(deployment, ["restart", "postgresql"])
    Compose.compose!(deployment, ["start", "control-plane"])
    deployment = Compose.wait_http!(deployment)

    assert Compose.docker!([
             "exec",
             name,
             "sh",
             "-ec",
             "kill -0 #{command_pid}; touch /workspace/sessions/unfinished/allow-read"
           ]) == ""

    assert_receive {:fake_llm_request, :compose_upgrade_read, 2, continued}, 120_000
    assert inspect(continued, limit: :infinity) =~ "legacy-work"
    assert read_input.() == input_before

    assert Compose.docker!([
             "exec",
             name,
             "cat",
             "/workspace/sessions/unfinished/read-count"
           ]) == "x"

    assert %{"workers" => workers} =
             Compose.api!(deployment, :get, "/api/v1/agent-workers")

    assert Enum.any?(workers, fn current ->
             current["agent_uid"] == uid and current["generation"] == worker["generation"] and
               current["state"] == "ready"
           end)

    Compose.api!(deployment, :delete, "/api/v1/agents/#{uid}/cron-schedules/#{schedule_id}")

    assert Compose.docker!([
             "exec",
             "--user",
             "1000:1000",
             name,
             "sh",
             "-ec",
             "test \"$(readlink /agents/#{uid})\" = /workspace; cat /workspace/sessions/unfinished/keep; cat /agents/#{uid}/sessions/unfinished/keep"
           ]) == "legacy-worklegacy-work"

    migration = String.trim(Compose.compose!(deployment, ["ps", "-aq", "migrate-agent-homes"]))
    control_plane = String.trim(Compose.compose!(deployment, ["ps", "-q", "control-plane"]))
    [migrated] = Compose.docker!(["inspect", migration]) |> Ankole.JSON.decode!()
    [started] = Compose.docker!(["inspect", control_plane]) |> Ankole.JSON.decode!()
    assert migrated["State"]["ExitCode"] == 0
    {:ok, finished_at, _} = DateTime.from_iso8601(migrated["State"]["FinishedAt"])
    {:ok, started_at, _} = DateTime.from_iso8601(started["State"]["StartedAt"])
    assert DateTime.compare(finished_at, started_at) != :gt

    [legacy] =
      Compose.docker!([
        "ps",
        "-aq",
        "--filter",
        "label=com.docker.compose.project=#{deployment.project}",
        "--filter",
        "label=com.docker.compose.service=worker"
      ])
      |> String.split("\n", trim: true)

    assert String.trim(Compose.docker!(["inspect", "--format", "{{.State.Running}}", legacy])) ==
             "false"

    # A second startup must not copy the old Home over newer work.
    Compose.docker!([
      "exec",
      "--user",
      "1000:1000",
      name,
      "sh",
      "-ec",
      "printf current-work > /workspace/sessions/unfinished/keep"
    ])

    Compose.compose!(deployment, [
      "up",
      "--no-deps",
      "--force-recreate",
      "--abort-on-container-exit",
      "--exit-code-from",
      "migrate-agent-homes",
      "migrate-agent-homes"
    ])

    assert Compose.docker!([
             "exec",
             "--user",
             "1000:1000",
             name,
             "cat",
             "/agents/#{uid}/sessions/unfinished/keep"
           ]) == "current-work"

    [inspection] = Compose.docker!(["inspect", name]) |> Ankole.JSON.decode!()
    volumes = for mount <- inspection["Mounts"], mount["Type"] == "volume", do: mount["Name"]
    assert length(volumes) == 2

    assert %{"agent" => %{"status" => "disabled"}} =
             Compose.api!(deployment, :delete, "/api/v1/agents/#{uid}")

    assert %{"agent" => %{"uid" => ^uid}} =
             Compose.api!(deployment, :delete, "/api/v1/agents/#{uid}")

    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               Enum.all?(
                 Compose.api!(deployment, :get, "/api/v1/agent-workers")["workers"],
                 &(&1["agent_uid"] != uid)
               )
             end)

    names =
      Compose.docker!(["volume", "ls", "--format", "{{.Name}}"]) |> String.split("\n", trim: true)

    for volume <- volumes, do: refute(volume in names)
  end

  @tag :real_llm
  @tag :real_llm_compose_chaos
  @tag timeout: 900_000
  test "a DeepSeek Lark request survives complete control-plane and PostgreSQL restarts without repeating its command" do
    platform = start_supervised!({FakeFeishu.State, owner: self()})

    server =
      start_supervised!(
        {Bandit,
         plug: {FakeFeishu.Router, state: platform}, scheme: :http, ip: {0, 0, 0, 0}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    app_id = "cli_compose_real_llm"
    app_secret = "compose-fake-platform-only"
    :ok = FakeFeishu.State.register_app(platform, app_id, app_secret, bot_open_id: "ou_bot")

    {old, owner} = Compose.start_legacy!() |> Compose.setup_admin!()
    uid = "compose-real-llm-agent"
    proof = "preserved-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    work = "/workspace/sessions/compose-real-llm"

    assert %{"agent" => %{"uid" => ^uid}} =
             Compose.api!(old, :post, "/api/v1/agents", %{
               uid: uid,
               display_name: "Compose recovery Agent",
               role: "Recover the user's report without repeating committed effects",
               owner_principal_uid: owner
             })

    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               Enum.any?(
                 Compose.api!(old, :get, "/api/v1/agent-computer-workers")["workers"],
                 &(&1["status"] == "ready")
               )
             end)

    Compose.compose!(old, [
      "exec",
      "-T",
      "worker",
      "sh",
      "-ec",
      "mkdir -p /agents/#{uid}/sessions/compose-real-llm; " <>
        "chmod 700 /agents/#{uid}; " <>
        "printf '%s\\n' '#{proof}' > /agents/#{uid}/sessions/compose-real-llm/source.txt"
    ])

    deployment = Compose.upgrade!(old, lark_base_url: "http://host.docker.internal:#{port}")
    compose_public_network_diagnostic!(deployment)

    Compose.api!(deployment, :put, "/api/v1/site/ai-gateway/providers/compose-real-model", %{
      provider_kind: "openrouter",
      base_url: "https://openrouter.ai/api/v1",
      credential_pool: %{
        entries: [%{label: "Test", api_key: Ankole.E2E.Harness.openrouter_api_key!()}]
      }
    })

    for profile <- ["primary", "light"] do
      Compose.api!(deployment, :put, "/api/v1/agents/#{uid}/model-profiles/#{profile}", %{
        provider_id: "compose-real-model",
        model: "deepseek/deepseek-v4.1-flash",
        context_length: 131_072
      })
    end

    Compose.api!(deployment, :put, "/api/v1/agents/#{uid}/signal-bindings/lark/compose-real", %{
      config: %{
        appID: app_id,
        appSecret: app_secret,
        domain: "feishu",
        userName: "Compose recovery bot"
      },
      group_message_mode: "addressed_only",
      unmatched_sender_policy: "create_standalone"
    })

    assert {:ok, true} =
             wait_until(deadline(60_000), fn ->
               FakeFeishu.State.connection_count(platform) == 1
             end)

    command =
      "printf x >> #{work}/run-count; echo $$ > #{work}/command.pid; " <>
        "while [ ! -e #{work}/allow-report ]; do sleep 0.1; done; " <>
        "cp #{work}/source.txt #{work}/recovered-report.txt"

    message_id = "om_compose_real_recovery"
    chat_id = "oc_compose_real_recovery"

    assert :ok =
             FakeFeishu.State.user_sends_message(platform,
               event_id: "evt_compose_real_recovery",
               message_id: message_id,
               chat_id: chat_id,
               chat_type: "p2p",
               text: """
               @_user_1 I need my preserved report delivered here as a file.
               Run this exact command once with the command tool and timeout 300:
               #{command}
               The wait is intentional. Do not cancel it or execute it again.
               After the command completes, use read_file to read #{work}/recovered-report.txt.
               Then use reply_attachment to send that absolute path and reply with the report's
               complete contents.
               If execution reconnects, keep the existing command and inspect its result;
               do not repeat a committed side effect. Do not use a background job or Workflow.
               """,
               mentions: [Ankole.E2E.Harness.lark_bot_mention()]
             )

    assert_receive {:fake_feishu, {:event_acked, "evt_compose_real_recovery", 200}}, 30_000

    assert {:ok, worker} =
             wait_until(deadline(120_000), fn ->
               Enum.find(
                 Compose.api!(deployment, :get, "/api/v1/agent-workers")["workers"],
                 &(&1["agent_uid"] == uid and &1["state"] == "ready")
               )
             end)

    name =
      Ankole.AgentWorkers.ProviderKind.instance_name(
        deployment.project,
        uid,
        worker["generation"]
      )

    pid_deadline = deadline(180_000)

    read_pid = fn ->
      pid =
        Compose.docker!([
          "exec",
          name,
          "sh",
          "-ec",
          "cat #{work}/command.pid 2>/dev/null || true"
        ])
        |> String.trim()

      if pid != "", do: pid
    end

    pid_result =
      case wait_until(deadline(90_000), read_pid) do
        {:ok, _pid} = ready ->
          ready

        :timeout ->
          IO.puts(
            "Compose command pending at 90 seconds.\n" <>
              compose_turn_diagnostic!(deployment, uid, message_id)
          )

          wait_until(pid_deadline, read_pid)
      end

    command_pid =
      case pid_result do
        {:ok, pid} ->
          pid

        :timeout ->
          flunk(
            "The model command did not create its PID file.\n" <>
              compose_turn_diagnostic!(deployment, uid, message_id)
          )
      end

    assert Compose.docker!(["exec", name, "cat", "#{work}/run-count"]) == "x"
    input_before = compose_input!(deployment, uid, message_id)
    assert input_before["attempt_count"] == 1
    assert input_before["completed"] == false

    Compose.compose!(deployment, ["stop", "control-plane"])
    stopped = String.trim(Compose.compose!(deployment, ["ps", "-aq", "control-plane"]))

    assert String.trim(Compose.docker!(["inspect", "--format", "{{.State.Running}}", stopped])) ==
             "false"

    restarted_at = DateTime.to_iso8601(DateTime.utc_now())
    Compose.compose!(deployment, ["restart", "postgresql"])
    Compose.compose!(deployment, ["start", "control-plane"])
    deployment = Compose.wait_http!(deployment)

    # No Driver, job, or queue is driven by the test. Production's scheduled
    # Reconciler must run against the restarted database before we release I/O.
    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               compose_query!(
                 deployment,
                 "SELECT to_json(EXISTS(SELECT 1 FROM oban_jobs " <>
                   "WHERE worker = 'Ankole.Sessions.Reconciler' AND state = 'completed' " <>
                   "AND attempted_at >= '#{restarted_at}'::timestamptz))"
               )
             end)

    assert Compose.docker!([
             "exec",
             name,
             "sh",
             "-ec",
             "kill -0 #{command_pid}; touch #{work}/allow-report"
           ]) == ""

    assert {:ok, {reply, file_message}} =
             wait_until(deadline(240_000), fn ->
               input = compose_input!(deployment, uid, message_id)
               visible = FakeFeishu.State.visible_messages(platform, chat_id)

               replies =
                 Enum.filter(
                   visible,
                   &(&1.sender == :bot and &1.msg_type == "text" and
                       String.contains?(&1.text || "", proof))
                 )

               files = Enum.filter(visible, &(&1.sender == :bot and &1.msg_type == "file"))

               case {input["completed"], replies, files} do
                 {true, [reply], [file]} -> {reply, file}
                 _pending -> nil
               end
             end)

    assert reply.reply_to == message_id
    assert file_message.reply_to == message_id
    assert {:ok, %{"file_key" => file_key}} = Ankole.JSON.decode(file_message.content)
    expected_bytes = proof <> "\n"

    assert %{name: "recovered-report.txt", content: ^expected_bytes} =
             FakeFeishu.State.uploaded_file(platform, file_key)

    assert Compose.docker!(["exec", name, "cat", "#{work}/run-count"]) == "x"

    assert Compose.docker!(["exec", name, "cat", "#{work}/recovered-report.txt"]) ==
             expected_bytes

    input_after = compose_input!(deployment, uid, message_id)
    assert input_after["id"] == input_before["id"]
    assert input_after["attempt_count"] == input_before["attempt_count"]
    input_id = input_after["id"]

    assert [%{"message_id" => sent_file_id, "attachments" => [_attachment]}] =
             compose_query!(
               deployment,
               "SELECT COALESCE(json_agg(json_build_object('message_id', created_provider_message_id, " <>
                 "'attachments', payload->'attachments')), '[]'::json) " <>
                 "FROM deliveries WHERE source_signal_id = '#{input_id}' " <>
                 "AND status = 'succeeded' AND jsonb_array_length(payload->'attachments') > 0"
             )

    assert sent_file_id == file_message.id

    assert Enum.any?(
             Compose.api!(deployment, :get, "/api/v1/agent-workers")["workers"],
             &(&1["agent_uid"] == uid and &1["generation"] == worker["generation"] and
                 &1["state"] == "ready")
           )
  end

  defp compose_input!(deployment, uid, message_id) do
    compose_query!(
      deployment,
      "SELECT json_build_object('id', id::text, 'attempt_count', attempt_count, " <>
        "'session_id', session_id, 'input_state', input_state, 'last_attempt_at', last_attempt_at, " <>
        "'completed', completed_at IS NOT NULL) FROM signals " <>
        "WHERE agent_uid = '#{uid}' AND provider_message_id = '#{message_id}'"
    )
  end

  defp compose_turn_diagnostic!(deployment, uid, message_id) do
    input = compose_input!(deployment, uid, message_id)

    messages =
      compose_query!(deployment, """
      SELECT COALESCE(json_agg(json_build_object(
        'id', id, 'status', status, 'type', type, 'content', content,
        'error_code', metadata #>> '{response,error,code}'
      ) ORDER BY inserted_at, id), '[]'::json)
      FROM ai_gateway_messages
      WHERE subject_uid = '#{uid}'
        AND metadata #>> '{request_metadata,signal_id}' = '#{input["id"]}'
      """)

    # Read only the Driver's phase and call state. Never inspect its request
    # context, provider configuration, authorization, or transport headers.
    code = """
    key = %{agent_uid: #{inspect(uid)}, session_id: #{inspect(input["session_id"])}}
    snapshot =
      case Ankole.Sessions.driver_pid(key) do
        :undefined -> %{state: :absent}
        pid ->
          try do
            {state, data} = :sys.get_state(pid, 1_000)
            %{
              state: state,
              stream_open: not is_nil(data.stream),
              run: if(data.run, do: Map.take(data.run,
                [:signal_id, :epoch, :iteration, :workspace_id, :workspace_open?, :recovered?])),
              tasks: Enum.map(data.tasks, fn {_ref, {kind, task}} ->
                %{kind: kind, current_function: Process.info(task, :current_function)}
              end),
              pending: Enum.map(data.pending, fn {id, pending} ->
                %{call_id: id, status: pending.status, tool: pending.worker_name,
                  mode: pending.mode, probe: pending.probe?,
                  arguments: Map.take(pending.args || %{},
                    ~w(command workdir timeout path name mimeType))}
              end)
            }
          catch
            :exit, reason -> %{state: :unavailable, reason: inspect(reason)}
          end
      end
    IO.puts(Ankole.JSON.encode!(Ankole.Signals.Sanitizer.transport(snapshot,
      max_depth: 10, max_items: 30, max_string: 2_000)))
    """

    driver =
      Compose.compose!(deployment, ["exec", "-T", "control-plane", "/app/bin/ankole", "rpc", code])

    trace =
      Enum.map(messages, fn message ->
        content = message["content"] || []

        %{
          id: message["id"],
          status: message["status"],
          type: message["type"],
          error_code: message["error_code"],
          tool_results:
            Ankole.E2E.Harness.tool_results([
              %Ankole.AIGateway.Schemas.Message{content: content}
            ]),
          text: for(%{"type" => "message", "content" => items} <- content, do: items)
        }
      end)

    logs =
      Compose.compose!(deployment, [
        "logs",
        "--no-color",
        "--no-log-prefix",
        "--tail",
        "300",
        "control-plane"
      ])
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Ankole.JSON.decode(line) do
          {:ok, %{"event" => event} = entry} when is_binary(event) ->
            if String.starts_with?(event, [
                 "ai_gateway.",
                 "conversation.",
                 "conversations.",
                 "sessions.",
                 "actor_runtime."
               ]) or
                 entry["severity"] in ["ERROR", "CRITICAL"] do
              fields =
                Map.take(entry, ~w(time event severity signal_id message_id state status
                error_code failure_kind error_stage provider_status upstream_host retryable))

              reason = entry["reason"]

              fields =
                if is_binary(reason) and Regex.match?(~r/\A:?[a-z][a-z0-9_.-]{0,100}\z/, reason),
                  do: Map.put(fields, "reason", reason),
                  else: fields

              [fields]
            else
              []
            end

          _other ->
            []
        end
      end)

    summary =
      Ankole.Signals.Sanitizer.transport(
        %{event: input, messages: trace, log_events: logs},
        max_depth: 12,
        max_items: 30,
        max_string: 2_000
      )

    "event_and_tape=#{Ankole.JSON.encode!(summary)}\ndriver=#{driver}"
  end

  defp compose_public_network_diagnostic!(deployment) do
    code = """
    result =
      case Req.get("https://openrouter.ai/api/v1/models",
        retry: false, receive_timeout: 10_000, connect_options: [timeout: 10_000]) do
        {:ok, response} -> %{status: response.status}
        {:error, %Req.TransportError{reason: reason}} -> %{transport_error: inspect(reason)}
        {:error, error} -> %{error_type: inspect(error.__struct__)}
      end
    IO.puts(Ankole.JSON.encode!(result))
    """

    result =
      Compose.compose!(deployment, ["exec", "-T", "control-plane", "/app/bin/ankole", "rpc", code])

    IO.puts("Compose public OpenRouter reachability (no credentials): #{String.trim(result)}")
  end

  defp compose_query!(deployment, sql) do
    Compose.compose!(deployment, [
      "exec",
      "-T",
      "postgresql",
      "sh",
      "-ec",
      "exec psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" \"$@\"",
      "psql",
      "-Atc",
      sql
    ])
    |> Ankole.JSON.decode!()
  end
end
