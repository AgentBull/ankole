defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.LambdaTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{
    Config,
    Lambda,
    ProviderKind,
    Providers,
    PrepareImageJob,
    ReconcileJob
  }

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.{Client, Images}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @fixtures Path.expand("../../../../fixtures/worker_providers/lambda/responses.json", __DIR__)
  @uid "agent-lambda"
  @ref "mvm-0123456789abcdef0"
  @api "/2025-09-09"

  setup do
    {:ok, runtime} = Config.fetch()
    previous = Application.get_env(:ankole, :lambda_api_req_options)
    Application.put_env(:ankole, :lambda_api_req_options, plug: {Req.Test, __MODULE__})

    :ok =
      Config.put(
        runtime
        |> Map.to_list()
        |> Keyword.merge(installation: "prod", image: "registry.example/worker:revision")
      )

    on_exit(fn ->
      Config.put(Map.to_list(runtime))

      if previous,
        do: Application.put_env(:ankole, :lambda_api_req_options, previous),
        else: Application.delete_env(:ankole, :lambda_api_req_options)
    end)

    row =
      worker_provider_fixture(%{
        provider_id: "lambda-test",
        kind: "lambda",
        config: Lambda.definition().example,
        credentials: %{
          "accessKeyId" => "AKIAEXAMPLE",
          "secretAccessKey" => "test-secret",
          "sessionToken" => "test-session"
        }
      })

    {:ok, provider} = Providers.load(row)

    %{
      provider: provider,
      spec: WorkerBootstrap.agent_worker_spec(provider, @uid, "gen0000001", "worker-secret")
    }
  end

  test "same-generation requests keep their token and image settings after a configuration edit",
       %{provider: provider, spec: spec} do
    stub(provider, fn conn ->
      assert {conn.method, conn.request_path} == {"POST", @api <> "/microvms"}
      {body, conn} = body(conn)
      send(self(), {:run, body})
      Req.Test.json(conn, fixture("microvm"))
    end)

    assert {:ok, @ref} = Lambda.create_instance(provider, spec)
    assert_received {:run, first}

    edited = %{
      provider
      | settings:
          provider.settings
          |> Map.put("networkConnectorArn", "new-connector")
          |> put_in(["endpoints", "runtimeFabricUrl"], "wss://changed.example/worker")
    }

    assert {:ok, @ref} = Lambda.create_instance(edited, spec)
    assert_received {:run, ^first}
    assert first["imageIdentifier"] == fixture("image")["imageArn"]
    assert first["maximumDurationInSeconds"] == 28_800

    assert first["idlePolicy"] == %{
             "autoResumeEnabled" => false,
             "maxIdleDurationSeconds" => 28_800,
             "suspendedDurationSeconds" => 28_800
           }

    refute Map.has_key?(first, "executionRoleArn")
    refute Map.has_key?(first, "imageVersion")
    contract = Ankole.JSON.decode!(first["runHookPayload"])

    assert Enum.sort(Map.keys(contract)) ==
             ~w(ANKOLE_RUNTIME_FABRIC_ENDPOINT ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY ANKOLE_WORKER_NFS_SOURCE ANKOLE_WORKER_STORAGE WORKER_ID)

    assert contract["WORKER_ID"] == @uid
    assert contract["ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY"] == "worker-secret"

    assert contract["ANKOLE_RUNTIME_FABRIC_ENDPOINT"] ==
             provider.settings["endpoints"]["runtimeFabricUrl"]

    assert contract["ANKOLE_WORKER_NFS_SOURCE"] ==
             "fs-0123456789abcdef0.efs.us-east-1.amazonaws.com:/ankole-agents"

    assert byte_size(first["runHookPayload"]) <= 4096
    assert {:ok, @ref} = Lambda.create_instance(provider, %{spec | generation: "gen0000002"})
    assert_received {:run, other}
    refute first["clientToken"] == other["clientToken"]
  end

  test "possible orphan VMs block a retry; peer providers and storage images are not listed", %{
    provider: provider,
    spec: spec
  } do
    own = owned_image(provider)
    peer = own |> Map.put("imageArn", "peer-image") |> put_in(["tags", "ankole-provider"], "peer")

    storage =
      own |> Map.put("imageArn", "storage-image") |> put_in(["tags", "ankole-role"], "storage")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        @api <> "/microvm-images" ->
          Req.Test.json(conn, %{"items" => [own, peer, storage]})

        @api <> "/microvms" ->
          assert conn.query_params["imageIdentifier"] == own["imageArn"]
          Req.Test.json(conn, %{"items" => [fixture("microvm")]})

        path ->
          image = Enum.find([own, peer, storage], &(path == image_path(&1["imageArn"])))
          assert image
          Req.Test.json(conn, image)
      end
    end)

    assert {:ok, [%{agent_uid: nil, generation: nil, instance_ref: @ref, phase: :running}]} =
             Lambda.list_instances(provider, :all)

    sent_at = DateTime.from_unix!(trunc(fixture("microvm")["startedAt"]))

    assert {:error, :lambda_waiting_for_provider_orphans} =
             Lambda.create_instance(provider, %{
               spec
               | create_retry?: true,
                 create_sent_at: sent_at
             })
  end

  test "a missing list checks the saved VM; only a terminal response can release it", %{
    provider: provider
  } do
    %{agent_uid: uid} = save_ref!(provider)

    for state <- ~w(PENDING RUNNING SUSPENDING SUSPENDED TERMINATING) do
      stub(provider, fn conn ->
        assert {conn.method, conn.request_path} == {"GET", @api <> "/microvms/" <> @ref}
        Req.Test.json(conn, Map.put(fixture("microvm"), "state", state))
      end)

      assert {:ok, [%{instance_ref: @ref, agent_uid: ^uid}]} =
               Lambda.list_instances(provider, uid)
    end

    stub(provider, &error(&1, 404, "ResourceNotFoundException"))

    assert {:error, {:lambda_api, 404, "ResourceNotFoundException"}} =
             Lambda.list_instances(provider, uid)

    stub(provider, &Req.Test.json(&1, Map.put(fixture("microvm"), "state", "TERMINATED")))
    assert {:ok, [%{phase: :exited}]} = Lambda.list_instances(provider, uid)

    Repo.get!(AgentWorker, uid)
    |> Ecto.Changeset.change(instance_seen_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, []} = Lambda.list_instances(provider, uid)

    # A 404 right after RunMicrovm can be eventual consistency, but a VM that
    # was observed before and now reads 404 is gone.
    stub(provider, &error(&1, 404, "ResourceNotFoundException"))
    assert {:ok, []} = Lambda.list_instances(provider, uid)
  end

  test "one Agent's unreadable saved VM does not stop another Agent's list", %{
    provider: provider
  } do
    %{agent_uid: uid} = save_ref!(provider)
    other = Ankole.PrincipalsFixtures.agent_fixture(%{worker_provider_id: provider.provider_id})

    stub(provider, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvms/" <> @ref} -> error(conn, 500, "InternalServerException")
        _other -> Req.Test.json(conn, %{"items" => []})
      end
    end)

    assert {:ok, []} = Lambda.list_instances(provider, other.principal.uid)
    assert {:ok, []} = Lambda.list_instances(provider, :all)
    assert {:error, {:lambda_api, 500, _}} = Lambda.list_instances(provider, uid)
  end

  test "an orphan observation cannot delete a reference that has since committed", %{
    provider: provider
  } do
    orphan = %{
      agent_uid: nil,
      instance_ref: @ref,
      started_at: DateTime.add(DateTime.utc_now(), -600)
    }

    stub(provider, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", @api <> "/microvms/" <> @ref}
      worker = save_ref!(provider)
      send(self(), {:committed_worker, worker.agent_uid})
      Req.Test.json(conn, fixture("microvm"))
    end)

    assert :ok = Lambda.delete_instance(provider, orphan, :now)
    assert_receive {:committed_worker, uid}
    assert Repo.get!(AgentWorker, uid).instance_ref == @ref
  end

  test "an unattributed VM younger than one sweep interval is not deleted", %{
    provider: provider
  } do
    # A pending create saves its reference within seconds. Until then its VM
    # is unattributed and must survive the sweep.
    stub(provider, fn conn -> flunk("unexpected request #{conn.method} #{conn.request_path}") end)

    for started_at <- [nil, DateTime.add(DateTime.utc_now(), -60)] do
      orphan = %{agent_uid: nil, instance_ref: @ref, started_at: started_at}
      assert :ok = Lambda.delete_instance(provider, orphan, :now)
    end
  end

  test "an old unattributed VM is deleted", %{provider: provider} do
    parent = self()

    stub(provider, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvms/" <> @ref} ->
          Req.Test.json(conn, fixture("microvm"))

        {"DELETE", @api <> "/microvms/" <> @ref} ->
          send(parent, :deleted)
          Req.Test.json(conn, %{})
      end
    end)

    orphan = %{
      agent_uid: nil,
      instance_ref: @ref,
      started_at: DateTime.add(DateTime.utc_now(), -600)
    }

    assert :ok = Lambda.delete_instance(provider, orphan, :now)
    assert_received :deleted
  end

  test "only an explicit nonretryable create refusal settles a generation", %{
    provider: provider,
    spec: spec
  } do
    for {status, code} <- [
          {402, "ServiceQuotaExceededException"},
          {409, "ConflictException"},
          {429, "ThrottlingException"},
          {500, "InternalServerException"},
          {503, "InsufficientCapacityException"},
          {404, "ResourceNotFoundException"}
        ] do
      stub(provider, &error(&1, status, code))
      assert {:error, {:lambda_api, ^status, ^code}} = Lambda.create_instance(provider, spec)
    end

    for {status, code} <- [{400, "ValidationException"}, {403, "AccessDeniedException"}] do
      stub(provider, &error(&1, status, code))
      assert {:rejected, {:lambda_api, ^status, ^code}} = Lambda.create_instance(provider, spec)
    end

    stub(provider, &Req.Test.transport_error(&1, :timeout))

    assert {:error, {:lambda_unreachable, %Req.TransportError{reason: :timeout}}} =
             Lambda.create_instance(provider, spec)

    assert {:error, :lambda_run_hook_payload_too_large} =
             Lambda.create_instance(provider, %{
               spec
               | env:
                   Map.put(
                     spec.env,
                     "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY",
                     String.duplicate("x", 4096)
                   )
             })
  end

  test "pause, resume, and termination preserve platform failures", %{provider: provider} do
    object = %{instance_ref: @ref, agent_uid: @uid, generation: "gen0000001"}

    for {fun, method, suffix} <- [
          {:pause_instance, "POST", "/suspend"},
          {:resume_instance, "POST", "/resume"},
          {:delete_instance, "DELETE", ""}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        if conn.method == "GET" do
          state = if fun == :resume_instance, do: "SUSPENDED", else: "RUNNING"
          Req.Test.json(conn, Map.put(fixture("microvm"), "state", state))
        else
          assert {conn.method, conn.request_path} ==
                   {method, @api <> "/microvms/" <> @ref <> suffix}

          error(conn, 503, "InternalServerException")
        end
      end)

      args = if fun == :delete_instance, do: [provider, object, :now], else: [provider, object]
      assert {:error, {:lambda_api, 503, "InternalServerException"}} = apply(Lambda, fun, args)
    end

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, Map.put(fixture("microvm"), "state", "TERMINATED"))
    end)

    assert {:error, :gone} = Lambda.resume_instance(provider, object)
    assert :ok = Lambda.delete_instance(provider, object, :now)
  end

  test "storage deletion reuses its token after an uncertain launch response", %{
    provider: provider
  } do
    parent = self()

    stub(
      provider,
      fn conn ->
        {request, conn} = body(conn)
        send(parent, {:delete_request, request})
        Req.Test.transport_error(conn, :timeout)
      end,
      "storage"
    )

    assert {:error, {:lambda_unreachable, _}} = Lambda.delete_storage(provider, @uid, nil)
    assert_received {:delete_request, request}
    refute Ankole.JSON.encode!(request) =~ "worker-secret"
    assert request["maximumDurationInSeconds"] == 3600

    stub(
      provider,
      fn conn ->
        {retry, conn} = body(conn)
        assert retry == request
        Req.Test.json(conn, fixture("microvm"))
      end,
      "storage"
    )

    assert {:pending, %{"microvmId" => @ref} = launched} =
             Lambda.delete_storage(provider, @uid, nil)

    for state <- ~w(PENDING SUSPENDING SUSPENDED TERMINATING) do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Map.put(fixture("microvm"), "state", state)))
      assert {:pending, ^launched} = Lambda.delete_storage(provider, @uid, launched)
    end

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, fixture("microvm")))
    assert {:ok, nil} = Lambda.delete_storage(provider, @uid, launched)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, Map.put(fixture("microvm"), "state", "TERMINATED"))
    )

    assert {:pending, nil} = Lambda.delete_storage(provider, @uid, launched)
  end

  test "managed image patches retain the settings of the selected image", %{provider: provider} do
    stub(
      provider,
      fn conn ->
        assert conn.method == "PUT"
        {body, conn} = body(conn)
        assert body["baseImageVersion"] == "2.0"
        assert body["resources"] == fixture("version")["resources"]
        assert body["environmentVariables"] == fixture("version")["environmentVariables"]
        assert body["buildRoleArn"] == provider.settings["buildRoleArn"]
        Req.Test.json(conn, fixture("update_response"))
      end,
      "worker",
      [
        %{"imageVersion" => "1.0", "status" => "DEPRECATED", "createdAt" => 1},
        %{"imageVersion" => "2.0", "status" => "AVAILABLE", "createdAt" => 2}
      ]
    )

    assert {:pending, :lambda_image_building} = Images.prepare(provider, "worker")
    assert {:snooze, 15} = perform_job(PrepareImageJob, %{provider_id: provider.provider_id})

    %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})
    assert {:snooze, 15} = perform_job(ReconcileJob, %{agent_uid: agent.uid})

    assert %{state: "absent", generation: nil, last_error_kind: "pending"} =
             Repo.get!(AgentWorker, agent.uid)

    assert {:wait, :preparing} =
             Ankole.SignalsGateway.ActorRuntime.AgentWorkers.workspace_status(agent.uid)
  end

  test "the listed managed version 1 is the built base version 1.0", %{provider: provider} do
    stub(provider, fn _ -> flunk("the available base must not be rebuilt") end, "worker", [
      %{"imageVersion" => "1", "status" => "AVAILABLE", "createdAt" => 1}
    ])

    assert :ok = Images.prepare(provider, "worker")
  end

  test "two sweeps prepare a changed image before the first Agent creates", %{provider: provider} do
    state = start_supervised!({Agent, fn -> :building end})
    changed = %{provider | runtime: %{provider.runtime | image: "registry.example/worker:next"}}
    {:ok, runtime} = Config.fetch()
    :ok = Config.put(Keyword.put(Map.to_list(runtime), :image, changed.runtime.image))
    image = owned_image(changed)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        @api <> "/microvm-images" ->
          Req.Test.json(conn, %{"items" => [image]})

        path ->
          cond do
            path == image_path(image["imageArn"]) ->
              stage = Agent.get(state, & &1)

              Req.Test.json(
                conn,
                if(stage == :building, do: Map.put(image, "state", "CREATING"), else: image)
              )

            path == image_path(image["imageArn"]) <> "/versions/1.0" ->
              Req.Test.json(conn, fixture("version"))

            String.contains?(path, "/managed-microvm-images/") ->
              Req.Test.json(conn, fixture("managed_versions"))

            true ->
              flunk("Unexpected image request: #{path}")
          end
      end
    end)

    assert :ok = perform_job(Ankole.SignalsGateway.ActorRuntime.AgentWorkers.SweepJob, %{})

    assert_enqueued(
      worker: PrepareImageJob,
      args: %{provider_id: provider.provider_id, image: changed.runtime.image}
    )

    assert {:snooze, 15} = perform_job(PrepareImageJob, %{provider_id: provider.provider_id})
    Agent.update(state, fn _ -> :ready end)
    assert :ok = perform_job(Ankole.SignalsGateway.ActorRuntime.AgentWorkers.SweepJob, %{})
    assert :ok = perform_job(PrepareImageJob, %{provider_id: provider.provider_id})
    assert :ok = Lambda.prepare_image(changed, changed.runtime.image)
    assert Repo.all(AgentWorker) == []
  end

  test "AWS credentials are paired, EFS is immutable, and instance settings cause replacement", %{
    provider: provider
  } do
    definition = Lambda.definition()
    {:ok, base} = Configuration.parse(definition.schema, definition.example)

    assert {:error, {:invalid_worker_provider_config, [%{path: "efs"}]}} =
             Configuration.unchanged_location(
               definition.schema,
               base,
               put_in(base["efs"]["root"], "/elsewhere")
             )

    refute Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, %{base | "memoryMiB" => 8192})

    assert Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, %{base | "buildBucket" => "new-builds"})

    assert {:error, {:invalid_worker_provider_credentials, _}} =
             Providers.create(%{
               provider_id: "incomplete-aws",
               kind: "lambda",
               display_name: "Incomplete",
               config: definition.example,
               credentials: %{"accessKeyId" => "key"}
             })

    assert :ok = Lambda.prepare_storage(provider, @uid)
    assert :ok = Lambda.delete_cache(provider, @uid)
  end

  defp stub(provider, extra, role \\ "worker", managed_versions \\ nil) do
    image = owned_image(provider) |> put_in(["tags", "ankole-role"], role)

    Req.Test.stub(__MODULE__, fn conn ->
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/"
      assert auth =~ "/us-east-1/lambda/aws4_request"

      assert auth =~
               "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token,"

      assert Plug.Conn.get_req_header(conn, "host") == ["lambda.us-east-1.amazonaws.com"]
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["test-session"]

      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvm-images"} ->
          Req.Test.json(conn, %{"items" => [Map.delete(image, "tags")]})

        {"GET", @api <> "/microvms"} ->
          Req.Test.json(conn, %{"items" => []})

        {"GET", path} ->
          cond do
            path == image_path(image["imageArn"]) ->
              Req.Test.json(conn, image)

            path == image_path(image["imageArn"]) <> "/versions/1.0" ->
              Req.Test.json(conn, fixture("version"))

            String.contains?(path, "/managed-microvm-images/") ->
              Req.Test.json(
                conn,
                if(managed_versions,
                  do: %{"items" => managed_versions},
                  else: fixture("managed_versions")
                )
              )

            true ->
              extra.(conn)
          end

        _ ->
          extra.(conn)
      end
    end)
  end

  defp owned_image(provider) do
    fixture("image")
    |> put_in(["tags", "ankole-settings"], provider.settings_digest)
    |> put_in(["tags", "ankole-source"], ProviderKind.hash16(provider.runtime.image))
  end

  defp save_ref!(provider) do
    %{principal: agent} = agent_fixture(%{handle: @uid, worker_provider_id: provider.provider_id})

    Repo.get!(AgentWorker, agent.uid)
    |> Ecto.Changeset.change(
      state: "starting",
      generation: "gen0000001",
      instance_ref: @ref,
      token_digest: <<1>>,
      token_ciphertext: <<2>>,
      image: provider.runtime.image,
      protocol_version: provider.runtime.protocol_version,
      settings_digest: provider.settings_digest
    )
    |> Repo.update!()
  end

  defp image_path(arn), do: @api <> "/microvm-images/" <> Client.path(arn)
  defp fixture(key), do: @fixtures |> File.read!() |> Ankole.JSON.decode!() |> Map.fetch!(key)

  defp body(conn) do
    {:ok, text, conn} = Plug.Conn.read_body(conn)
    {Ankole.JSON.decode!(text), conn}
  end

  defp error(conn, status, code),
    do:
      conn
      |> Plug.Conn.put_resp_header("x-amzn-errortype", code)
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"message" => "detail"})
end
