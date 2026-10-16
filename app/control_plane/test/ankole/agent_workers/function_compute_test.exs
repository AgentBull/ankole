defmodule Ankole.AgentWorkers.FunctionComputeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.FunctionCompute
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ProviderKind

  alias Ankole.AgentWorkers.FunctionCompute.Images
  alias Ankole.AgentWorkers.FunctionCompute.Signature
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap

  @fixtures Path.expand(
              "../../fixtures/worker_providers/function_compute/responses.json",
              __DIR__
            )
  @uid "agent-fc"

  setup do
    {:ok, runtime} = Config.fetch()
    previous = Application.get_env(:ankole, :function_compute_req_options)
    Application.put_env(:ankole, :function_compute_req_options, plug: {Req.Test, __MODULE__})

    Config.put(
      runtime
      |> Map.to_list()
      |> Keyword.merge(installation: "prod", image: "worker:revision")
    )

    on_exit(fn ->
      Config.put(Map.to_list(runtime))

      if previous,
        do: Application.put_env(:ankole, :function_compute_req_options, previous),
        else: Application.delete_env(:ankole, :function_compute_req_options)
    end)

    row =
      worker_provider_fixture(%{
        provider_id: "fc-test",
        kind: "function_compute",
        config: FunctionCompute.definition().example,
        credentials: %{
          "apiKey" => "test-api-key",
          "accessKeyId" => "test-ak",
          "accessKeySecret" => "test-secret",
          "securityToken" => "test-sts"
        }
      })

    {:ok, provider} = Providers.load(row)

    %{
      provider: provider,
      spec: WorkerBootstrap.agent_worker_spec(provider, @uid, "gen0000001", "worker-secret")
    }
  end

  test "ACS3 matches the official fixed-parameter example" do
    uri =
      URI.parse(
        "https://ecs.cn-shanghai.aliyuncs.com/?ImageId=win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd&RegionId=cn-shanghai"
      )

    headers = [
      {"host", uri.host},
      {"x-acs-action", "RunInstances"},
      {"x-acs-content-sha256",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
      {"x-acs-date", "2023-10-26T10:22:32Z"},
      {"x-acs-signature-nonce", "3156853299f313e23d1673dc12e1703d"},
      {"x-acs-version", "2014-05-26"}
    ]

    signed =
      Signature.sign(:post, uri, headers, "", %{
        "accessKeyId" => "YourAccessKeyId",
        "accessKeySecret" => "YourAccessKeySecret"
      })

    assert List.keyfind(signed, "authorization", 0) ==
             {"authorization",
              "ACS3-HMAC-SHA256 Credential=YourAccessKeyId,SignedHeaders=host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version,Signature=06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0"}

    assert Signature.query(%{"Quota.FileCountLimit" => 100_000, "FileSystemPath" => "/a b/~"}) ==
             "FileSystemPath=%2Fa%20b%2F~&Quota.FileCountLimit=100000"
  end

  test "templates use the second-generation entry and signed ROA requests", %{provider: provider} do
    stub(fn conn ->
      assert conn.host == "sandbox.cn-hangzhou.aliyuncs.com"
      assert conn.request_path == "/pop/2026-08-20/templates"
      assert_signed(conn)

      case conn.method do
        "GET" ->
          assert conn.query_params == %{"teamID" => "team_example", "maxResults" => "100"}
          Req.Test.json(conn, %{"templates" => []})

        "POST" ->
          {body, conn} = body(conn)
          assert body["teamID"] == "team_example"

          assert body["runtimeConfig"] == %{
                   "cpu" => 2,
                   "memorySize" => 4096,
                   "diskSize" => 15360,
                   "internetAccess" => true,
                   "sandboxConfig" => %{
                     "generation" => 2,
                     "image" =>
                       "instance-registry-vpc.cn-hangzhou.cr.aliyuncs.com/ankole/worker:revision",
                     "startCommand" =>
                       "sudo env ANKOLE_WORKER_BOOTSTRAP=function_compute /usr/local/bin/ankole-worker-entry",
                     "readyCommand" => "sudo test -f /run/ankole/awaiting-contract"
                   }
                 }

          send(self(), {:template_name, body["name"]})
          Req.Test.json(conn, fixture("template_created"))
      end
    end)

    assert {:pending, :function_compute_template_building} =
             FunctionCompute.prepare_image(provider, "worker:revision")

    assert_receive {:template_name, name}
    ready = Map.put(fixture("template"), "name", name)
    stub(fn conn -> Req.Test.json(conn, %{"templates" => [ready]}) end)
    assert :ok = FunctionCompute.prepare_image(provider, "worker:revision")
    assert {:ok, "tpl_example"} = Images.selected(provider, "worker:revision")

    # Concurrent image preparation can leave an equivalent unfinished build.
    building =
      ready |> Map.put("templateID", "tpl_building") |> put_in(["status", "state"], "building")

    stub(fn conn -> Req.Test.json(conn, %{"templates" => [building, ready]}) end)
    assert :ok = FunctionCompute.prepare_image(provider, "worker:revision")
    assert {:ok, "tpl_example"} = Images.selected(provider, "worker:revision")
  end

  test "repeated creates get no credential; the saved reference alone gets a root contract", %{
    provider: provider,
    spec: spec
  } do
    template = template(provider, spec.image)
    sandbox = sandbox(provider)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/pop/2026-08-20/templates"} ->
          Req.Test.json(conn, %{"templates" => [template]})

        {"POST", "/sandboxes"} ->
          assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-api-key"]
          {body, conn} = body(conn)
          assert body["timeout"] == 86400
          assert body["secure"]
          assert body["templateID"] == "tpl_example"
          assert body["metadata"]["ankole-generation"] == "gen0000001"
          assert body["metadata"]["ankole.tenant"] == Repo.tenant_id!()
          assert [%{"name" => name, "path" => "/workspace"}] = body["volumeMounts"]
          assert String.starts_with?(name, ProviderKind.storage_name("prod", @uid) <> "-ap-")
          refute Ankole.JSON.encode!(body) =~ "worker-secret"
          Req.Test.json(conn, fixture("sandbox_created"))

        {"GET", "/sandboxes/sandbox-selected"} ->
          Req.Test.json(conn, sandbox)

        {"POST", "/files"} ->
          assert conn.host == "49983-sandbox-selected.cn-hangzhou.sandbox.aliyuncs.com"

          assert conn.query_params == %{
                   "path" => "/run/ankole/contract.json",
                   "username" => "root"
                 }

          assert Plug.Conn.get_req_header(conn, "x-access-token") == ["test-envd-token"]
          assert Plug.Conn.get_req_header(conn, "e2b-sandbox-id") == ["sandbox-selected"]
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          assert raw =~ "name=\"file\"; filename=\"/run/ankole/contract.json\""
          assert raw =~ "worker-secret"
          assert raw =~ "ANKOLE_WORKER_STORAGE"
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, "sandbox-selected"} = FunctionCompute.create_instance(provider, spec)
    assert {:ok, "sandbox-selected"} = FunctionCompute.create_instance(provider, spec)

    assert {:ok, "sandbox-selected"} =
             FunctionCompute.create_instance(provider, %{spec | instance_ref: "sandbox-selected"})
  end

  test "list reads every page, filters provider metadata, and queries missing saved references",
       %{provider: provider} do
    %{principal: %{uid: uid}} =
      agent_fixture(%{handle: @uid, worker_provider_id: provider.provider_id})

    Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid),
      set: [
        state: "starting",
        generation: "gen0000001",
        instance_ref: "sandbox-selected",
        token_digest: <<1>>,
        token_ciphertext: <<1>>,
        image: provider.runtime.image,
        protocol_version: provider.runtime.protocol_version,
        settings_digest: provider.settings_digest
      ]
    )

    selected = sandbox(provider) |> put_in(["metadata", "ankole-agent"], ProviderKind.hash16(uid))
    other = put_in(selected["metadata"]["ankole-provider"], "other")

    stub(fn conn ->
      case conn.request_path do
        "/v2/sandboxes" ->
          assert conn.query_params["state"] == "running,paused"

          assert URI.decode_query(conn.query_params["metadata"]) ==
                   FunctionCompute.labels(provider)

          case conn.query_params["nextToken"] do
            nil ->
              conn |> Plug.Conn.put_resp_header("x-next-token", "next") |> Req.Test.json([other])

            "next" ->
              Req.Test.json(conn, [])
          end

        "/sandboxes/sandbox-selected" ->
          Req.Test.json(conn, Map.put(selected, "state", "paused"))
      end
    end)

    assert {:ok,
            [
              %{
                agent_uid: ^uid,
                phase: :paused,
                instance_ref: "sandbox-selected",
                started_at: nil
              }
            ]} =
             Repo.without_tenant(fn -> FunctionCompute.list_instances(provider, :all) end)
  end

  test "a Worker committed on the final inventory page keeps its owner", %{provider: provider} do
    tenant_id = Repo.tenant_id!()

    stub(fn conn ->
      # A site-wide read must not extend its tenant bypass into provider I/O.
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(AgentWorker) end
      assert conn.request_path == "/v2/sandboxes"

      case conn.query_params["nextToken"] do
        nil ->
          conn |> Plug.Conn.put_resp_header("x-next-token", "last") |> Req.Test.json([])

        "last" ->
          uid =
            Repo.with_tenant(tenant_id, fn ->
              %{principal: agent} =
                agent_fixture(%{handle: @uid, worker_provider_id: provider.provider_id})

              agent.uid
            end)

          send(self(), {:committed_worker, uid})

          selected =
            sandbox(provider) |> put_in(["metadata", "ankole-agent"], ProviderKind.hash16(uid))

          Req.Test.json(conn, [selected])
      end
    end)

    assert {:ok, [%{agent_uid: uid, instance_ref: "sandbox-selected"}]} =
             Repo.without_tenant(fn -> FunctionCompute.list_instances(provider, :all) end)

    assert_receive {:committed_worker, ^uid}
  end

  test "a later inventory page failure does not return partial orphan observations", %{
    provider: provider
  } do
    stub(fn conn ->
      assert conn.method == "GET"
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(AgentWorker) end

      case conn.query_params["nextToken"] do
        nil ->
          conn
          |> Plug.Conn.put_resp_header("x-next-token", "last")
          |> Req.Test.json([sandbox(provider)])

        "last" ->
          error(conn, 503)
      end
    end)

    assert {:error, {:function_compute_api, 503, "Unavailable", "retry"}} =
             Repo.without_tenant(fn -> FunctionCompute.list_instances(provider, :all) end)
  end

  test "pause preserves memory and resume sets the new lifetime; errors remain errors", %{
    provider: provider
  } do
    object = %{instance_ref: "sandbox-selected"}

    stub(fn conn ->
      {body, conn} = body(conn)

      case conn.request_path do
        "/sandboxes/sandbox-selected/pause" -> assert body == %{"memory" => true}
        "/sandboxes/sandbox-selected/connect" -> assert body == %{"timeout" => 86400}
      end

      Req.Test.json(conn, %{})
    end)

    assert :ok = FunctionCompute.pause_instance(provider, object)
    assert :ok = FunctionCompute.resume_instance(provider, object)
    stub(&error(&1, 503))

    assert {:error, {:function_compute_api, 503, "Unavailable", "retry"}} =
             FunctionCompute.delete_instance(provider, object, :now)

    stub(&error(&1, 404))
    assert :ok = FunctionCompute.delete_instance(provider, object, :now)
    assert {:error, :gone} = FunctionCompute.resume_instance(provider, object)
  end

  test "OSS resume runs the image recovery command as root and waits for its exit", %{
    provider: provider
  } do
    provider = put_in(provider.settings["storage"], %{"oss" => %{}})

    Application.put_env(:ankole, :function_compute_req_options,
      adapter: fn request ->
        case request.url.path do
          "/sandboxes/sandbox-selected/connect" ->
            assert Ankole.JSON.decode!(request.body) == %{"timeout" => 86400}
            {request, Req.Response.new(status: 200, body: fixture("sandbox_created"))}

          "/process.Process/Start" ->
            assert request.url.host == "49983-sandbox-selected.cn-hangzhou.sandbox.aliyuncs.com"
            assert Req.Request.get_header(request, "authorization") == ["Basic cm9vdDo="]
            assert Req.Request.get_header(request, "x-access-token") == ["test-envd-token"]
            assert Req.Request.get_header(request, "e2b-sandbox-id") == ["sandbox-selected"]
            assert Req.Request.get_header(request, "e2b-sandbox-port") == ["49983"]
            assert Req.Request.get_header(request, "connect-timeout-ms") == ["15000"]
            assert Req.Request.get_header(request, "content-type") == ["application/connect+json"]
            <<0, size::32, payload::binary-size(size)>> = request.body

            assert Ankole.JSON.decode!(payload) == %{
                     "process" => %{
                       "cmd" => "/usr/bin/python3",
                       "args" => ["/usr/local/libexec/function-compute-resume-oss.py"]
                     }
                   }

            # envd omits the protobuf default exitCode=0 in a successful exit.
            response =
              frame(0, %{event: %{start: %{pid: 4870}}}) <>
                frame(0, %{event: %{end: %{exited: true, status: "exit status 0"}}}) <>
                frame(2, %{})

            {request, Req.Response.new(status: 200, body: response)}
        end
      end
    )

    assert :ok = FunctionCompute.resume_instance(provider, %{instance_ref: "sandbox-selected"})
  end

  test "OSS resume ends the instance when the recovery command fails", %{provider: provider} do
    provider = put_in(provider.settings["storage"], %{"oss" => %{}})
    test_pid = self()

    for {response, expected} <- [
          {frame(0, %{event: %{end: %{exited: true, exitCode: 1}}}) <> frame(2, %{}),
           {:function_compute_storage_resume, 1}},
          {frame(2, %{error: %{code: "permission_denied"}}),
           {:function_compute_storage_resume, %{"code" => "permission_denied"}}},
          {frame(0, %{event: %{start: %{pid: 42}}}) <> frame(2, %{}),
           :function_compute_command_incomplete},
          {frame(0, %{event: %{end: %{exited: true}}}), :function_compute_command_incomplete},
          {<<0, 15::32, "truncated">>, :function_compute_command_incomplete},
          {frame(0, %{"unexpected" => true}), :function_compute_command_invalid}
        ] do
      Application.put_env(:ankole, :function_compute_req_options,
        adapter: fn request ->
          body =
            case {request.method, request.url.path} do
              {:post, "/sandboxes/sandbox-selected/connect"} ->
                fixture("sandbox_created")

              {:post, "/process.Process/Start"} ->
                response

              {:delete, "/sandboxes/sandbox-selected"} ->
                send(test_pid, :instance_deleted)
                %{}
            end

          {request, Req.Response.new(status: 200, body: body)}
        end
      )

      assert {:error, ^expected} =
               FunctionCompute.resume_instance(provider, %{instance_ref: "sandbox-selected"})

      assert_received :instance_deleted
    end

    # A deletion failure is the reported error: the instance still exists.
    Application.put_env(:ankole, :function_compute_req_options,
      adapter: fn request ->
        case {request.method, request.url.path} do
          {:post, "/sandboxes/sandbox-selected/connect"} ->
            {request, Req.Response.new(status: 200, body: fixture("sandbox_created"))}

          {:post, "/process.Process/Start"} ->
            {request,
             Req.Response.new(
               status: 200,
               body: frame(0, %{event: %{end: %{exited: true, exitCode: 1}}}) <> frame(2, %{})
             )}

          {:delete, "/sandboxes/sandbox-selected"} ->
            {request,
             Req.Response.new(status: 503, body: %{"code" => "Unavailable", "message" => "retry"})}
        end
      end
    )

    assert {:error, {:function_compute_api, 503, "Unavailable", "retry"}} =
             FunctionCompute.resume_instance(provider, %{instance_ref: "sandbox-selected"})
  end

  defp frame(flags, value) do
    payload = Ankole.JSON.encode!(value)
    <<flags, byte_size(payload)::32, payload::binary>>
  end

  test "AgenticFS creates space, access point, and Volume; deletion uses their IDs in reverse order",
       %{provider: provider} do
    name = ProviderKind.storage_name("prod", @uid)

    space =
      put_in(
        fixture("spaces"),
        ["AgenticSpaces", "AgenticSpace", Access.at(0), "FileSystemPath"],
        "/" <> name <> "/"
      )

    Process.put(:stage, :space)

    stub(fn conn ->
      assert_signed(conn)
      action = List.first(Plug.Conn.get_req_header(conn, "x-acs-action"))

      case action do
        "DescribeAgenticSpaces" ->
          Req.Test.json(
            conn,
            if(Process.get(:stage) == :space,
              do: put_in(space["AgenticSpaces"]["AgenticSpace"], []),
              else: space
            )
          )

        "CreateAgenticSpace" ->
          assert conn.query_params["FileSystemPath"] == "/" <> name
          assert conn.query_params["Quota.SizeLimit"] == "107374182400"
          assert conn.query_params["Quota.FileCountLimit"] == "100000"
          Process.put(:stage, :access_point)
          Req.Test.json(conn, fixture("space_created"))

        "DescribeAccessPoints" ->
          Req.Test.json(conn, Process.get(:points, %{"AccessPoints" => []}))

        "CreateAccessPoint" ->
          q = conn.query_params
          assert q["AgenticSpaceId"] == "agentic-example"
          assert q["EnabledRam"] == "true"
          assert q["VpcId"] == "vpc-example"
          assert q["VswId"] == "vsw-example"
          refute Map.has_key?(q, "RootDirectory")

          point =
            fixture("access_points")
            |> put_in(["AccessPoints", Access.at(0), "AccessPointName"], q["AccessPointName"])
            |> put_in(
              ["AccessPoints", Access.at(0), "Tags"],
              Enum.map(1..3, &%{"Key" => q["Tag.#{&1}.Key"], "Value" => q["Tag.#{&1}.Value"]})
            )

          Process.put(:points, point)
          Req.Test.json(conn, fixture("access_point_created"))

        "ListVolumes" ->
          Req.Test.json(conn, Process.get(:volumes, %{"volumes" => []}))

        "CreateVolume" ->
          {body, conn} = body(conn)

          assert body["agenticFSVolumeConfig"] ==
                   fixture("volumes")["volumes"] |> hd() |> Map.fetch!("agenticFSVolumeConfig")

          Process.put(
            :volumes,
            put_in(
              fixture("volumes"),
              ["volumes", Access.at(0), "volumeName"],
              body["volumeName"]
            )
          )

          Req.Test.json(conn, fixture("volume_created"))

        "DeleteVolume" ->
          assert conn.request_path == "/pop/2026-08-20/volumes/vol-example"
          Process.delete(:volumes)
          Req.Test.json(conn, %{})

        "DeleteAccessPoint" ->
          assert conn.query_params["AccessPointId"] == "ap-example"
          Process.delete(:points)
          Req.Test.json(conn, %{})

        "DeleteAgenticSpace" ->
          assert conn.query_params["AgenticSpaceId"] == "agentic-example"
          Process.put(:stage, :space)
          Req.Test.json(conn, %{})
      end
    end)

    assert {:error, :function_compute_space_pending} =
             FunctionCompute.prepare_storage(provider, @uid)

    assert {:error, :function_compute_access_point_pending} =
             FunctionCompute.prepare_storage(provider, @uid)

    assert :ok = FunctionCompute.prepare_storage(provider, @uid)
    assert :ok = FunctionCompute.prepare_storage(provider, @uid)
    assert {:pending, nil} = FunctionCompute.delete_storage(provider, @uid, nil)
    assert {:pending, nil} = FunctionCompute.delete_storage(provider, @uid, nil)
    assert {:pending, nil} = FunctionCompute.delete_storage(provider, @uid, nil)
    assert {:ok, nil} = FunctionCompute.delete_storage(provider, @uid, nil)
  end

  test "create uncertainty never rejects a generation", %{provider: provider, spec: spec} do
    for status <- [409, 429, 500, 503] do
      stub(fn conn ->
        if conn.request_path == "/pop/2026-08-20/templates",
          do: Req.Test.json(conn, %{"templates" => [template(provider, spec.image)]}),
          else: error(conn, status)
      end)

      assert {:error, {:function_compute_api, ^status, _, _}} =
               FunctionCompute.create_instance(provider, spec)
    end

    for status <- [400, 401, 403, 422] do
      stub(fn conn ->
        if conn.request_path == "/pop/2026-08-20/templates",
          do: Req.Test.json(conn, %{"templates" => [template(provider, spec.image)]}),
          else: error(conn, status)
      end)

      assert {:rejected, {:function_compute_api, ^status, _, _}} =
               FunctionCompute.create_instance(provider, spec)
    end

    stub(fn conn ->
      if conn.request_path == "/pop/2026-08-20/templates",
        do: Req.Test.json(conn, %{"templates" => [template(provider, spec.image)]}),
        else: Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:function_compute_unreachable, %Req.TransportError{reason: :timeout}}} =
             FunctionCompute.create_instance(provider, spec)
  end

  test "OSS deletion saves a selection before sending its contract and waits for helper removal",
       %{provider: provider} do
    provider =
      put_in(provider.settings["storage"], %{
        "oss" => %{"bucket" => "test-bucket", "root" => "/ankole"}
      })

    helper = sandbox(provider)
    Process.put(:helper_gone, false)
    Process.put(:completed, false)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/pop/2026-08-20/templates"} ->
          Req.Test.json(conn, %{"templates" => [template(provider, provider.runtime.image)]})

        {"POST", "/sandboxes"} ->
          {body, conn} = body(conn)
          mount = Ankole.JSON.decode!(body["metadata"]["fc.sandbox.storage.oss"])

          assert mount == fixture("oss_mount")

          assert body["metadata"]["ankole-task"] == "storage"
          refute Ankole.JSON.encode!(body) =~ "delete_storage"
          Process.put(:helper_metadata, body["metadata"])
          Req.Test.json(conn, helper)

        {"GET", "/sandboxes/sandbox-selected"} ->
          if Process.get(:helper_gone), do: error(conn, 404), else: Req.Test.json(conn, helper)

        {"GET", "/v2/sandboxes"} ->
          extra =
            helper
            |> Map.put("sandboxID", "extra")
            |> Map.put("metadata", Process.get(:helper_metadata))

          peer =
            put_in(extra["metadata"]["ankole-provider"], "other") |> Map.put("sandboxID", "peer")

          Req.Test.json(conn, [extra, peer])

        {"DELETE", "/sandboxes/extra"} ->
          Req.Test.json(conn, %{})

        {"DELETE", "/sandboxes/sandbox-selected"} ->
          assert Process.get(:completed)
          Process.put(:helper_gone, true)
          Req.Test.json(conn, %{})

        {"GET", "/files"} ->
          assert conn.query_params["path"] == "/run/ankole/task-done"
          if Process.get(:completed), do: Req.Test.json(conn, ""), else: error(conn, 404)

        {"POST", "/files"} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          assert raw =~ "delete_storage"
          Process.put(:completed, true)
          Req.Test.json(conn, [])
      end
    end)

    assert {:pending, %{"task_id" => _, "request" => _} = intent} =
             FunctionCompute.delete_storage(provider, @uid, nil)

    refute Map.has_key?(intent, "sandbox_id")

    assert {:pending, %{"sandbox_id" => "sandbox-selected"} = selected} =
             FunctionCompute.delete_storage(provider, @uid, intent)

    refute Process.get(:completed)
    assert {:pending, ^selected} = FunctionCompute.delete_storage(provider, @uid, selected)

    assert {:pending, %{"completed" => true} = completed} =
             FunctionCompute.delete_storage(provider, @uid, selected)

    assert {:pending, ^completed} = FunctionCompute.delete_storage(provider, @uid, completed)
    assert {:ok, nil} = FunctionCompute.delete_storage(provider, @uid, completed)
  end

  test "file quota errors name their YAML path and VPC changes preserve storage", %{
    provider: provider
  } do
    alias Ankole.AgentWorkers.Providers.Configuration
    schema = FunctionCompute.definition().schema
    yaml = String.replace(provider.config, "    fileCountLimit: 100000\n", "")
    assert {:error, {:invalid_worker_provider_config, errors}} = Configuration.parse(schema, yaml)
    assert Enum.any?(errors, &(&1.path == "storage.agenticFs.fileCountLimit"))
    updated = put_in(provider.settings["vpc"]["vpcId"], "vpc-replacement")
    assert :ok = Configuration.unchanged_location(schema, provider.settings, updated.settings)

    refute Configuration.digest(schema, provider.settings) ==
             Configuration.digest(schema, updated.settings)

    changed = put_in(provider.settings["storage"]["agenticFs"]["fileCountLimit"], 200_000)

    assert {:error, {:invalid_worker_provider_config, [%{path: "storage"}]}} =
             Configuration.unchanged_location(schema, provider.settings, changed.settings)
  end

  defp template(provider, image) do
    digest =
      ProviderKind.hash16(
        :erlang.term_to_binary({provider.provider_id, provider.settings_digest, image})
      )

    Map.put(fixture("template"), "name", "ankole-#{provider.runtime.installation}-#{digest}")
  end

  defp sandbox(provider),
    do:
      Map.put(
        fixture("sandbox"),
        "metadata",
        Map.merge(FunctionCompute.labels(provider), %{
          "ankole-agent" => ProviderKind.hash16(@uid),
          "ankole-generation" => "gen0000001"
        })
      )

  defp fixture(key), do: @fixtures |> File.read!() |> Ankole.JSON.decode!() |> Map.fetch!(key)

  defp stub(fun),
    do: Req.Test.stub(__MODULE__, fn conn -> fun.(Plug.Conn.fetch_query_params(conn)) end)

  defp body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Ankole.JSON.decode!(raw), conn}
  end

  defp error(conn, status),
    do:
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"code" => "Unavailable", "message" => "retry"})

  defp assert_signed(conn) do
    [auth] = Plug.Conn.get_req_header(conn, "authorization")

    assert auth =~
             "SignedHeaders=content-type;host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-security-token;x-acs-signature-nonce;x-acs-version"

    assert Plug.Conn.get_req_header(conn, "x-acs-security-token") == ["test-sts"]
    assert Plug.Conn.get_req_header(conn, "host") == [conn.host]
  end
end
