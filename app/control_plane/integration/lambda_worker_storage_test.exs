defmodule Ankole.LambdaWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.WorkerStorageFixtures
  import Ankole.E2E.Harness
  alias Ankole.E2E.{FakeOpenAIState, Scenarios.ScheduleAndTool}
  alias Ankole.Principals
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Lambda

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap

  # Initial, replacement, and storage-cleanup images each require an AWS build.
  @moduletag cloud: true, sandbox: false, timeout: 3_600_000

  setup %{tenant: tenant} = context do
    secrets =
      System.fetch_env!("ANKOLE_LAMBDA_TEST_CREDENTIALS_FILE")
      |> File.read!()
      |> Ankole.JSON.decode!()

    config = System.fetch_env!("ANKOLE_LAMBDA_TEST_CONFIG_FILE") |> File.read!()
    {:ok, settings} = YamlElixir.read_from_string(config)
    origin = System.fetch_env!("ANKOLE_LAMBDA_TEST_CP_ORIGIN")
    image = System.fetch_env!("ANKOLE_LAMBDA_TEST_IMAGE")
    replacement = System.get_env("ANKOLE_LAMBDA_TEST_REPLACEMENT_IMAGE")
    port = System.fetch_env!("ANKOLE_LAMBDA_TEST_CP_PORT") |> String.to_integer()
    unless context[:drive_vfs], do: assert(is_binary(replacement) and image != replacement)
    {:ok, previous} = Config.fetch()
    :ok = Config.put(previous |> Map.to_list() |> Keyword.put(:image, image))
    on_exit(fn -> Config.put(Map.to_list(previous)) end)
    Ankole.E2E.Harness.start_ai_gateway_test_http_server!(port)

    %{principal: owner} = human_fixture()

    config =
      settings
      |> Map.put("idleReleaseAfter", "never")
      |> Map.put("endpoints", %{
        "runtimeFabricUrl" =>
          String.replace_prefix(origin, "https://", "wss://") <> "/runtime-fabric/worker",
        "relayOrigin" => origin,
        "aiGatewayUrl" => origin <> "/api/v1/ai-gateway"
      })
      |> Ankole.JSON.encode!()

    {uids, ids} =
      storage_agents!(
        "lambda",
        Ankole.Ecto.UUIDv7.autogenerate(),
        owner.uid,
        config,
        secrets,
        if(context[:drive_vfs], do: 1, else: 2)
      )

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> cleanup_storage!(uids, ids, owner.uid) end)

      cleanup_tenant!(tenant)
    end)

    assert {:ok, _} = FakeOpenAIState.start_link(self())
    llm_port = start_fake_llm_server!()
    fake_feishu = start_fake_feishu!()
    {:ok, agent} = Principals.get_principal(hd(uids))
    domain = setup_lark_domain!(llm_port, fake_feishu, agent)
    start_lark_connections!(fake_feishu, connections: 3)

    flow =
      Map.merge(domain, %{
        fake_feishu: fake_feishu,
        container: %{kind: :lambda, agent_uid: agent.uid}
      })

    %{uids: uids, replacement: replacement, runtime: previous, owner: owner, flow: flow}
  end

  @tag drive_vfs: true
  test "mounted ChatDrive remains readable and writable across Lambda freeze/thaw", context do
    [uid] = context.uids
    first = await_worker_state!(uid, :ready)
    assert first.capacity["drive_vfs"] == true

    conversation_id =
      assert_drive_delivery!(context.flow, "lambda_fuse_before",
        chat_id: "oc_lambda_drive_freeze"
      )

    IO.puts("Lambda real FUSE mount and ChatDrive write passed")

    assert {:ok, _} = Principals.delete_agent(uid)
    paused = await_worker_state!(uid, :paused)
    assert paused.instance_ref == first.instance_ref
    {:ok, provider} = Providers.load(first.provider_id)
    assert {:ok, [%{phase: :paused}]} = Lambda.list_instances(provider, uid)
    Process.sleep(65_000)
    assert {:ok, _} = Principals.enable_agent(uid)
    resumed = await_worker_state!(uid, :ready)
    assert resumed.instance_ref == first.instance_ref
    assert resumed.incarnation_id == first.incarnation_id
    assert resumed.capacity["drive_vfs"] == true

    assert assert_drive_delivery!(context.flow, "lambda_fuse_after",
             resume: true,
             chat_id: "oc_lambda_drive_freeze"
           ) ==
             conversation_id

    IO.puts("Same ChatDrive read, append, and delivery passed after 65-second Lambda pause")
  end

  test "EFS survives pause, termination, and image replacement; deletion removes only its Agent",
       context do
    [uid, peer_uid] = context.uids
    first = await_worker_state!(uid, :ready)
    assert first.capacity["drive_vfs"] == true
    assert_drive_delivery!(context.flow, "before_pause")
    IO.puts("Mounted ChatDrive atomic save and attachment delivery passed")

    peer = await_worker_state!(peer_uid, :ready)
    assert peer.capacity["drive_vfs"] == true
    IO.puts("Both Lambda Workers mounted FUSE")

    # The peer image build can take minutes. A connection can change without
    # an instance change, so obtain the current connection before file RPCs.
    assert {:ok, connected} = AgentWorkers.connected_worker(uid)
    assert connected.generation == first.generation
    assert connected.instance_ref == first.instance_ref
    first = connected

    {:ok, provider} = Providers.load(first.provider_id)
    {:ok, peer_provider} = Providers.load(peer.provider_id)
    put_proof!(first, "HOME-BEFORE-PAUSE")
    put_proof!(peer, "OTHER-PROVIDER")
    assert {:ok, [%{agent_uid: ^uid, instance_ref: ref}]} = Lambda.list_instances(provider, :all)
    assert ref == first.instance_ref
    assert {:ok, [%{agent_uid: ^peer_uid}]} = Lambda.list_instances(peer_provider, :all)

    assert {:ok, token} = AgentWorkers.credential(first)
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, first.generation, token)
    assert {:ok, ^ref} = Lambda.create_instance(provider, %{spec | instance_ref: ref})

    assert {:ok, _} = Principals.delete_agent(uid)
    paused = await_worker_state!(uid, :paused)
    assert paused.generation == first.generation
    assert {:ok, [%{phase: :paused}]} = Lambda.list_instances(provider, uid)
    # Cross the Worker's 60-second freeze detector with the mounted Drive idle.
    Process.sleep(65_000)
    assert {:ok, _} = Principals.enable_agent(uid)
    assert :ok = AgentWorkers.request(uid)
    resumed = await_worker_state!(uid, :ready)
    assert resumed.instance_ref == first.instance_ref
    assert resumed.incarnation_id == first.incarnation_id
    assert_proof!(resumed, "HOME-BEFORE-PAUSE")
    assert_drive_delivery!(context.flow, "after_resume")
    IO.puts("Home and mounted ChatDrive delivery survived the 65-second pause")

    # Terminate through the real AWS adapter outside reconciliation. A new
    # generation must mount the same EFS directory after AWS confirms exit.
    put_proof!(resumed, "HOME-BEFORE-TERMINATION")

    assert :ok =
             Lambda.delete_instance(
               provider,
               %{
                 agent_uid: uid,
                 generation: resumed.generation,
                 instance_ref: resumed.instance_ref
               },
               :now
             )

    recovered = await_worker_state!(uid, :ready, resumed.generation)
    refute recovered.instance_ref == resumed.instance_ref
    assert_proof!(recovered, "HOME-BEFORE-TERMINATION")
    assert recovered.capacity["drive_vfs"] == true
    assert_drive_delivery!(context.flow, "after_recreation")
    IO.puts("EFS Home and Drive delivery survived instance termination and recreation")

    put_proof!(recovered, "HOME-BEFORE-IMAGE-CHANGE")
    :ok = Config.put(context.runtime |> Map.to_list() |> Keyword.put(:image, context.replacement))
    changed = await_worker_state!(uid, :ready, recovered.generation)
    assert changed.image == context.replacement
    assert_proof!(changed, "HOME-BEFORE-IMAGE-CHANGE")
    assert changed.capacity["drive_vfs"] == true
    assert_drive_delivery!(context.flow, "after_image_change")
    IO.puts("EFS Home and Drive delivery survived replacement with the second image")
    assert {:ok, _} = Principals.delete_agent(uid)
    assert {:ok, _} = Principals.delete_agent(uid)
    assert await_worker_state!(uid, nil) == nil
    assert {:ok, []} = Lambda.list_instances(provider, uid)
    assert_proof!(Repo.get_by!(AgentWorker, agent_uid: peer_uid), "OTHER-PROVIDER")
    assert {:ok, [%{generation: generation}]} = Lambda.list_instances(peer_provider, :all)
    assert generation == peer.generation
    IO.puts("Agent deletion preserved the other provider's instance and Home")
  end

  defp assert_drive_delivery!(flow, suffix, opts \\ []) do
    assert {:ok, _} = FakeOpenAIState.start_link(self())

    %{intent: intent, input: input} =
      ScheduleAndTool.run_reply_attachment_tool_loop(
        flow,
        Keyword.merge([drive: true, suffix: suffix], opts)
      )

    sent = dispatch_succeeded!(intent)
    delivered = platform_message!(flow.fake_feishu, sent.created_provider_message_id)
    assert delivered.msg_type == "file"
    assert delivered.reply_to == "om_reply_attachment_#{suffix}"
    assert {:ok, %{"file_key" => key}} = Ankole.JSON.decode(delivered.content)

    content =
      "CHAOS_REPLY_ATTACHMENT_FILE" <> if(opts[:resume], do: "\nRESUMED", else: "")

    assert %{name: "drive-report.txt", content: ^content} =
             FakeFeishu.State.uploaded_file(flow.fake_feishu.state, key)

    input.conversation_id
  end
end
