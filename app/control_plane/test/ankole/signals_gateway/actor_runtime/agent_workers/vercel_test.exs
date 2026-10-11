defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.VercelTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Config, ProviderKind, Providers, Vercel}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration

  # Shape sources and the limits of these unit fixtures are in SOURCES.md.
  @fixtures Path.expand("../../../../fixtures/worker_providers/vercel/responses.json", __DIR__)
  @uid "agent-vercel"
  @ref "sbx_selected"

  setup do
    {:ok, runtime} = Config.fetch()
    previous = Application.get_env(:ankole, :vercel_api_req_options)
    Application.put_env(:ankole, :vercel_api_req_options, plug: {Req.Test, __MODULE__})

    :ok =
      Config.put(
        runtime
        |> Map.to_list()
        |> Keyword.merge(
          installation: "prod",
          image: "worker@sha256:" <> String.duplicate("a", 64)
        )
      )

    on_exit(fn ->
      :ok = Config.put(Map.to_list(runtime))

      if previous,
        do: Application.put_env(:ankole, :vercel_api_req_options, previous),
        else: Application.delete_env(:ankole, :vercel_api_req_options)
    end)

    row =
      worker_provider_fixture(%{
        provider_id: "vercel-test",
        kind: "vercel",
        config: Vercel.definition().example,
        credentials: %{"token" => "test-token"}
      })

    {:ok, provider} = Providers.load(row)

    %{
      provider: provider,
      spec: WorkerBootstrap.agent_worker_spec(provider, @uid, "gen0000001", "worker-secret")
    }
  end

  test "a create receives no launch credential; only its returned session can receive the entry command",
       %{provider: provider, spec: spec} do
    stub(fn conn ->
      assert {conn.method, conn.request_path} == {"POST", "/v4/sandboxes"}
      {body, conn} = body(conn)
      assert body["tags"]["ankole.tenant"] == Repo.tenant_id!()

      assert put_in(body["tags"], Map.delete(body["tags"], "ankole.tenant")) ==
               fixture("create_request")

      refute Ankole.JSON.encode!(body) =~ "worker-secret"
      Req.Test.json(conn, fixture("create_response"))
    end)

    assert {:ok, @ref} = Vercel.create_instance(provider, spec)
    assert {:ok, @ref} = Vercel.create_instance(provider, spec)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/sandboxes/sessions/" <> @ref} ->
          Req.Test.json(conn, fixture("session_response"))

        {"GET", "/v2/sandboxes/sessions/" <> @ref <> "/cmd"} ->
          Req.Test.json(conn, %{"commands" => []})

        {"POST", "/v2/sandboxes/sessions/" <> @ref <> "/cmd"} ->
          {body, conn} = body(conn)
          command = fixture("command_response")["command"]
          assert body["command"] == command["name"]
          assert body["args"] == command["args"]
          assert body["cwd"] == command["cwd"]
          assert body["sudo"] == false
          assert body["wait"] == false
          assert body["env"] == spec.env
          refute Map.has_key?(body, "timeout")
          Req.Test.json(conn, fixture("command_response"))
      end
    end)

    assert {:ok, @ref} = Vercel.create_instance(provider, %{spec | instance_ref: @ref})
  end

  test "entry retries observe the existing command without starting it again, including after exit",
       %{provider: provider, spec: spec} do
    for code <- [nil, 0, 1] do
      stub(fn conn ->
        assert conn.method == "GET"

        case conn.request_path do
          "/v2/sandboxes/sessions/" <> @ref ->
            Req.Test.json(conn, fixture("session_response"))

          "/v2/sandboxes/sessions/" <> @ref <> "/cmd" ->
            Req.Test.json(conn, %{
              "commands" => [
                put_in(fixture("command_response")["command"]["exitCode"], code)["command"]
              ]
            })
        end
      end)

      assert {:ok, @ref} = Vercel.create_instance(provider, %{spec | instance_ref: @ref})
    end
  end

  test "image preparation, throttling, conflicts, and connection failures never reject a generation",
       %{provider: provider, spec: spec} do
    for {status, code} <- [
          {400, "image_not_ready"},
          {409, "drive_attached"},
          {429, "rate_limit"},
          {500, "internal_error"},
          {503, "unavailable"}
        ] do
      stub(&error(&1, status, code))

      assert {:error, {:vercel_api, ^status, ^code, "detail"}} =
               Vercel.create_instance(provider, spec)
    end

    for status <- [400, 401, 403, 422] do
      stub(&error(&1, status, "invalid_request"))

      assert {:rejected, {:vercel_api, ^status, "invalid_request", "detail"}} =
               Vercel.create_instance(provider, spec)
    end

    stub(&Req.Test.transport_error(&1, :timeout))

    assert {:error, {:vercel_unreachable, %Req.TransportError{reason: :timeout}}} =
             Vercel.create_instance(provider, spec)

    assert {:error, :vercel_image_digest_required} =
             Vercel.prepare_image(provider, "worker:latest")
  end

  test "listing follows cursors and exact provider tags, and retains terminating sessions", %{
    provider: provider
  } do
    selected = fixture("create_response")["sandbox"]
    peer = put_in(selected["tags"]["ankole-provider"], "peer") |> Map.put("name", "peer")

    other_installation =
      put_in(selected["tags"]["ankole-installation"], "prod-eu")
      |> Map.put("name", "other-installation")

    session = fixture("session_response")["session"]
    extra = %{session | "id" => "sbx_extra", "status" => "stopping"}

    stub(fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/sandboxes" ->
          assert conn.query_params["tags"] == "ankole-installation:prod"
          assert conn.query_params["project"] == "prj_example"
          assert conn.query_params["limit"] == "50"

          case conn.query_params["cursor"] do
            nil -> page(conn, "sandboxes", [peer, other_installation], "page-2")
            "page-2" -> page(conn, "sandboxes", [selected])
          end

        "/v2/sandboxes/sessions" ->
          assert conn.query_params["name"] == selected["name"]

          case conn.query_params["cursor"] do
            nil -> page(conn, "sessions", [session], "sessions-2")
            "sessions-2" -> page(conn, "sessions", [extra])
          end

        "/v2/sandboxes/sessions/" <> @ref <> "/cmd" ->
          page_commands(conn, [])
      end
    end)

    assert {:ok,
            [
              %{agent_uid: @uid, instance_ref: @ref, phase: :starting},
              %{instance_ref: "sbx_extra", phase: :terminating}
            ]} = Vercel.list_instances(provider, @uid)

    assert {:ok, [%{agent_uid: nil}, %{agent_uid: nil}]} = Vercel.list_instances(provider, :all)
  end

  test "a Worker row committed during a platform list is not an orphan", %{provider: provider} do
    stub(fn conn ->
      case conn.request_path do
        "/v2/sandboxes" ->
          %{principal: agent} =
            agent_fixture(%{handle: @uid, worker_provider_id: provider.provider_id})

          save_ref!(provider, agent.uid)
          send(self(), {:committed_worker, agent.uid})

          sandbox =
            fixture("create_response")["sandbox"]
            |> Map.put(
              "name",
              ProviderKind.instance_name(provider.runtime.installation, agent.uid, "gen0000001")
            )
            |> put_in(["tags", "ankole-agent"], ProviderKind.hash16(agent.uid))

          page(conn, "sandboxes", [sandbox])

        "/v2/sandboxes/sessions" ->
          page(conn, "sessions", [fixture("session_response")["session"]])

        "/v2/sandboxes/sessions/" <> @ref <> "/cmd" ->
          page_commands(conn, [fixture("command_response")["command"]])
      end
    end)

    assert {:ok, [%{agent_uid: uid, instance_ref: @ref, phase: :running}]} =
             Vercel.list_instances(provider, :all)

    assert_receive {:committed_worker, ^uid}
  end

  test "a missing named list does not hide a saved running session", %{provider: provider} do
    %{principal: agent} = agent_fixture(%{handle: @uid, worker_provider_id: provider.provider_id})
    save_ref!(provider, agent.uid)

    stub(fn conn ->
      case conn.request_path do
        "/v2/sandboxes" ->
          page(conn, "sandboxes", [])

        "/v2/sandboxes/sessions/" <> @ref ->
          Req.Test.json(conn, fixture("session_response"))

        "/v2/sandboxes/sessions/" <> @ref <> "/cmd" ->
          page_commands(conn, [fixture("command_response")["command"]])
      end
    end)

    assert {:ok, [%{instance_ref: @ref, phase: :running}]} =
             Vercel.list_instances(provider, agent.uid)
  end

  test "a missing session list rechecks the sandbox's current ID instead of deleting its metadata",
       %{provider: provider} do
    stub(fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/sandboxes" -> page(conn, "sandboxes", [fixture("create_response")["sandbox"]])
        "/v2/sandboxes/sessions" -> page(conn, "sessions", [])
        "/v2/sandboxes/sessions/" <> @ref -> error(conn, 503, "unavailable")
      end
    end)

    assert {:error, {:vercel_api, 503, "unavailable", "detail"}} =
             Vercel.list_instances(provider, @uid)
  end

  test "an entry retry rejected by flock does not hide the original running entry", %{
    provider: provider
  } do
    entry = fixture("command_response")["command"]

    stub(fn conn ->
      case conn.request_path do
        "/v2/sandboxes" ->
          page(conn, "sandboxes", [fixture("create_response")["sandbox"]])

        "/v2/sandboxes/sessions" ->
          page(conn, "sessions", [fixture("session_response")["session"]])

        "/v2/sandboxes/sessions/" <> @ref <> "/cmd" ->
          page_commands(conn, [%{entry | "id" => "cmd_retry", "exitCode" => 1}, entry])
      end
    end)

    assert {:ok, [%{phase: :running}]} = Vercel.list_instances(provider, @uid)
  end

  test "deletion stops only the extra session and keeps a selected session of the same named sandbox",
       %{provider: provider} do
    session = fixture("session_response")["session"]
    object = object("sbx_extra")

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/sandboxes/sessions/sbx_extra"} ->
          Req.Test.json(conn, %{"session" => %{session | "id" => "sbx_extra"}})

        {"POST", "/v2/sandboxes/sessions/sbx_extra/stop"} ->
          assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

          Req.Test.json(conn, %{
            "session" => %{session | "id" => "sbx_extra", "status" => "stopping"}
          })

        {"GET", "/v2/sandboxes/sessions"} ->
          page(conn, "sessions", [
            %{session | "id" => "sbx_extra", "status" => "stopped"},
            session
          ])

        _ ->
          flunk("must not delete the named sandbox or stop the selected session")
      end
    end)

    assert :ok = Vercel.delete_instance(provider, object, :now)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/sandboxes/sessions/sbx_extra"} ->
          Req.Test.json(conn, %{
            "session" => %{session | "id" => "sbx_extra", "status" => "stopped"}
          })

        {"GET", "/v2/sandboxes/sessions"} ->
          send(self(), :selected_session_retained)

          page(conn, "sessions", [
            %{session | "id" => "sbx_extra", "status" => "stopped"},
            session
          ])

        _ ->
          flunk("a stopped extra session must not stop the selected session")
      end
    end)

    assert :ok = Vercel.delete_instance(provider, object, :now)
    assert_received :selected_session_retained
  end

  test "deletion waits for all sessions to stop before removing named metadata", %{
    provider: provider
  } do
    object = object(@ref)

    for status <- ["stopping", "stopped"] do
      stub(fn conn ->
        session = %{fixture("session_response")["session"] | "status" => status}

        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes/sessions/" <> @ref} ->
            Req.Test.json(conn, %{"session" => session})

          {"GET", "/v2/sandboxes/sessions"} ->
            page(conn, "sessions", [session])

          {"DELETE", path} ->
            assert status == "stopped"
            assert path == "/v2/sandboxes/" <> object.sandbox_name
            send(self(), :metadata_deleted)
            Req.Test.json(conn, %{"sandbox" => fixture("create_response")["sandbox"]})
        end
      end)

      assert :ok = Vercel.delete_instance(provider, object, :now)

      if status == "stopped",
        do: assert_received(:metadata_deleted),
        else: refute_received(:metadata_deleted)
    end

    stub(&error(&1, 503, "unavailable"))

    assert {:error, {:vercel_api, 503, "unavailable", "detail"}} =
             Vercel.delete_instance(provider, object, :now)
  end

  test "graceful deletion sends SIGTERM and reports a failed signal command", %{
    provider: provider
  } do
    for exit_code <- [0, 1] do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes/sessions/" <> @ref <> "/cmd"} ->
            page_commands(conn, [fixture("command_response")["command"]])

          {"POST", "/v2/sandboxes/sessions/" <> @ref <> "/cmd"} ->
            {body, conn} = body(conn)

            assert body == %{
                     "command" => "bash",
                     "args" => ["-ec", "kill -TERM \"$(cat /run/ankole-worker.pid)\""],
                     "sudo" => false,
                     "wait" => false
                   }

            Req.Test.json(conn, %{
              "command" => %{fixture("command_response")["command"] | "id" => "cmd_stop"}
            })

          {"GET", "/v2/sandboxes/sessions/" <> @ref <> "/cmd/cmd_stop"} ->
            assert conn.query_params["wait"] == "true"

            Req.Test.json(conn, %{
              "command" => %{
                fixture("command_response")["command"]
                | "id" => "cmd_stop",
                  "exitCode" => exit_code
              }
            })
        end
      end)

      result = Vercel.delete_instance(provider, object(@ref), :graceful)

      if exit_code == 0,
        do: assert(result == :ok),
        else: assert(result == {:error, {:vercel_command_failed, "cmd_stop", 1}})
    end
  end

  test "Drive create uses its stable name and delete refuses an attached Drive", %{
    provider: provider
  } do
    drive = fixture("drive_response")["drive"]
    path = "/v2/sandboxes/drives/" <> drive["name"]

    stub(fn conn ->
      assert {conn.method, conn.request_path} == {"POST", path}
      {body, conn} = body(conn)

      assert body == %{
               "projectId" => "prj_example",
               "region" => "iad1",
               "maxSizeBytes" => 107_374_182_400
             }

      Req.Test.json(conn, fixture("drive_response"))
    end)

    assert :ok = Vercel.prepare_storage(provider, @uid)
    assert :ok = Vercel.prepare_storage(provider, @uid)

    stub(fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/sandboxes/drives"}
      assert conn.query_params["sortBy"] == "name"
      assert conn.query_params["namePrefix"] == drive["name"]
      page(conn, "drives", [Map.put(drive, "currentSessionId", @ref)])
    end)

    assert {:error, {:vercel_drive_attached, @ref}} = Vercel.delete_storage(provider, @uid, nil)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/sandboxes/drives"} ->
          assert conn.query_params["sortBy"] == "name"
          assert conn.query_params["namePrefix"] == drive["name"]
          page(conn, "drives", [drive, %{drive | "name" => drive["name"] <> "-peer"}])

        {"DELETE", ^path} ->
          assert conn.query_params["projectId"] == "prj_example"
          Req.Test.json(conn, fixture("drive_response"))
      end
    end)

    assert {:ok, nil} = Vercel.delete_storage(provider, @uid, nil)
    assert :ok = Vercel.delete_cache(provider, @uid)
    assert {:ok, nil, nil} = Vercel.current_storage_ref(provider, @uid)
    assert {:error, :pause_not_supported} = Vercel.pause_instance(provider, object(@ref))
    assert {:error, :pause_not_supported} = Vercel.resume_instance(provider, object(@ref))
  end

  test "schema keeps storage and location immutable and CPU in the replacement digest" do
    definition = Vercel.definition()
    {:ok, base} = Configuration.parse(definition.schema, definition.example)

    for cpus <- [0, 3, 33, 1.5] do
      assert {:error, {:invalid_worker_provider_config, [%{path: "cpus"}]}} =
               Configuration.parse(
                 definition.schema,
                 Ankole.JSON.encode!(%{base | "cpus" => cpus})
               )
    end

    for key <- ~w(teamId projectId region driveSizeGiB) do
      assert {:error, {:invalid_worker_provider_config, [%{path: ^key}]}} =
               Configuration.unchanged_location(
                 definition.schema,
                 base,
                 Map.put(base, key, "changed")
               )
    end

    refute Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, %{base | "cpus" => 4})

    assert Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, %{base | "stopGraceSeconds" => 30})

    assert {:error, {:invalid_worker_provider_config, [%{path: "env.WORKER_ID"}]}} =
             Configuration.parse(
               definition.schema,
               Ankole.JSON.encode!(%{base | "env" => %{"WORKER_ID" => "wrong"}})
             )
  end

  defp save_ref!(provider, uid) do
    Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid),
      set: [
        state: "starting",
        generation: "gen0000001",
        instance_ref: @ref,
        instance_seen_at: DateTime.utc_now(),
        image: provider.runtime.image,
        protocol_version: provider.runtime.protocol_version,
        settings_digest: provider.settings_digest,
        token_digest: :crypto.strong_rand_bytes(32),
        token_ciphertext: "encrypted"
      ]
    )
  end

  defp fixture(key), do: @fixtures |> File.read!() |> Ankole.JSON.decode!() |> Map.fetch!(key)

  defp object(id),
    do: %{
      agent_uid: @uid,
      generation: "gen0000001",
      instance_ref: id,
      sandbox_name: fixture("create_response")["sandbox"]["name"]
    }

  defp stub(fun),
    do:
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["teamId"] == "team_example"
        fun.(conn)
      end)

  defp body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Ankole.JSON.decode!(body), conn}
  end

  defp error(conn, status, code),
    do:
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => %{"code" => code, "message" => "detail"}})

  defp page(conn, key, rows, next \\ nil),
    do:
      Req.Test.json(conn, %{
        key => rows,
        "pagination" => %{"count" => length(rows), "next" => next}
      })

  defp page_commands(conn, commands), do: Req.Test.json(conn, %{"commands" => commands})
end
