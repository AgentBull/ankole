defmodule Ankole.AgentWorkers.KubernetesAPITest do
  use ExUnit.Case, async: false

  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.WorkerBootstrap

  @cluster __MODULE__.Cluster
  @namespace "ankole"
  @agent "agent-a"
  @generation "gen0000001"

  # Paths, selectors, metadata, DeleteOptions, and status fields:
  # https://github.com/kubernetes/kubernetes/blob/v1.37.1/api/openapi-spec/swagger.json
  # The production Kubereq client sends every request to this unit-test boundary.
  setup do
    Ankole.Repo.put_tenant_id(Ecto.UUID.generate())
    previous = Application.fetch_env(:ankole, :kubereq)

    Application.put_env(:ankole, :kubereq,
      kubeconfig: {Kubereq.Kubeconfig.Stub, plugs: {Req.Test, @cluster}}
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, :kubereq, value)
        :error -> Application.delete_env(:ankole, :kubereq)
      end
    end)

    {:ok, settings} =
      Configuration.parse(Kubernetes.definition().schema, Kubernetes.definition().example)

    %{
      provider: %Provider{
        provider_id: "cluster",
        kind: "kubernetes",
        settings: settings,
        secrets: %{},
        runtime: %{
          installation: "prod",
          image: "worker:test",
          runtime_fabric_endpoint: "ws://control-plane:4000/runtime-fabric/worker"
        }
      }
    }
  end

  test "checks access to the named owner ConfigMap without requiring access to other ConfigMaps",
       %{provider: provider} do
    provider = put_in(provider.settings["ownerConfigMap"], "workers")
    parent = self()

    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      attributes = Ankole.JSON.decode!(body)["spec"]["resourceAttributes"]

      if attributes["resource"] == "configmaps" do
        assert attributes["name"] == "workers"
        assert attributes["verb"] == "get"
        send(parent, :owner_checked)
      end

      Req.Test.json(conn, %{"status" => %{"allowed" => true}})
    end)

    assert :ok = Kubernetes.check(provider)
    assert_received :owner_checked
  end

  test "creates a Secret and Pod, and propagates a partial creation failure", %{
    provider: provider
  } do
    spec = WorkerBootstrap.agent_worker_spec(provider, @agent, @generation, "test-token")
    parent = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Ankole.JSON.decode!(body)
      assert body["metadata"]["labels"]["ankole.io/provider"] == "cluster"
      assert body["metadata"]["annotations"]["ankole.io/agent-uid"] == @agent

      case {conn.method, path(conn)} do
        {"POST", "secrets"} ->
          assert body["stringData"] == %{"ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "test-token"}
          send(parent, :secret_created)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(Map.put(body, "metadata", metadata(name())))

        {"POST", "pods"} ->
          assert_received :secret_created
          refute inspect(body) =~ "test-token"
          assert body["spec"]["restartPolicy"] == "Never"
          assert body["spec"]["automountServiceAccountToken"] == false
          [container] = body["spec"]["containers"]

          assert container["securityContext"] == %{
                   "runAsUser" => 0,
                   "runAsGroup" => 0,
                   "runAsNonRoot" => false,
                   "allowPrivilegeEscalation" => false,
                   "capabilities" => %{
                     "drop" => ["ALL"],
                     "add" => ~w(SETUID SETGID CHOWN FOWNER DAC_OVERRIDE KILL)
                   },
                   "seccompProfile" => %{"type" => "RuntimeDefault"}
                 }

          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"kind" => "Status", "message" => "unavailable"})
      end
    end)

    assert {:error, {:kubernetes_api, 503, "unavailable"}} =
             Kubernetes.create_instance(provider, spec)
  end

  test "keeps a terminating Pod and its Secret visible until the platform removes the Pod", %{
    provider: provider
  } do
    for {mode, grace} <- [now: "1", graceful: "60"] do
      stub(fn conn ->
        case {conn.method, path(conn)} do
          {"DELETE", "pods/" <> _} ->
            assert conn.query_params["gracePeriodSeconds"] == grace
            Req.Test.json(conn, %{"kind" => "Status", "status" => "Success"})

          {"GET", "pods/" <> _} ->
            Req.Test.json(
              conn,
              pod(name(), "Running", %{"deletionTimestamp" => "2026-10-07T00:00:00Z"})
            )
        end
      end)

      assert :ok = Kubernetes.delete_instance(provider, instance(), mode)
    end

    stub(fn conn ->
      case {conn.method, path(conn)} do
        {"DELETE", "pods/" <> _} -> status(conn, 404)
        {"GET", "pods/" <> _} -> status(conn, 404)
        {"DELETE", "secrets/" <> _} -> status(conn, 404)
      end
    end)

    assert :ok = Kubernetes.delete_instance(provider, instance(), :now)

    stub(&status(&1, 403))

    assert {:error, {:kubernetes_api, 403, _}} =
             Kubernetes.delete_instance(provider, instance(), :now)
  end

  test "lists every page and unions Pods with partial Secrets within one provider", %{
    provider: provider
  } do
    stub(fn conn ->
      assert conn.method == "GET"
      selector = conn.query_params["labelSelector"]
      assert selector =~ "ankole.io/installation=prod"
      assert selector =~ "ankole.io/provider=cluster"
      assert selector =~ "ankole.io/task=worker"

      case {path(conn), conn.query_params["continue"]} do
        {"pods", nil} ->
          Req.Test.json(conn, %{
            "kind" => "PodList",
            "metadata" => %{"continue" => "next-page"},
            "items" => [pod(name(), "Running", %{"deletionTimestamp" => "2026-10-07T00:00:00Z"})]
          })

        {"pods", "next-page"} ->
          Req.Test.json(conn, %{
            "kind" => "PodList",
            "items" => [pod("pod-without-secret", "Failed")]
          })

        {"secrets", nil} ->
          Req.Test.json(conn, %{
            "kind" => "SecretList",
            "items" => [
              %{"metadata" => metadata(name())},
              %{"metadata" => metadata("secret-without-pod")}
            ]
          })
      end
    end)

    assert {:ok, instances} = Kubernetes.list_instances(provider, :all)

    assert Map.new(instances, &{&1.instance_ref, &1.phase}) == %{
             name() => :terminating,
             "pod-without-secret" => :exited,
             "secret-without-pod" => :exited
           }
  end

  test "checks the full Agent UID after its hash selector and retains Worker logs", %{
    provider: provider
  } do
    stub(fn conn ->
      case path(conn) do
        "pods" ->
          assert conn.query_params["labelSelector"] =~
                   "ankole.io/agent=#{ProviderKind.hash16(@agent)}"

          foreign =
            put_in(
              pod("hash-collision", "Running"),
              ["metadata", "annotations", "ankole.io/agent-uid"],
              "other-agent"
            )

          Req.Test.json(conn, %{"items" => [pod(name(), "Running"), foreign]})

        "secrets" ->
          Req.Test.json(conn, %{"items" => []})

        "events" ->
          Req.Test.json(conn, %{"items" => []})

        log ->
          assert log == "pods/#{name()}/log"
          assert conn.query_params["tailLines"] == "50"
          Plug.Conn.send_resp(conn, 200, "cannot reach control plane\n")
      end
    end)

    assert {:ok, [%{phase: :running, reason: "cannot reach control plane", agent_uid: @agent}]} =
             Kubernetes.list_instances(provider, @agent)
  end

  test "persistent claims have no owner while cache claims belong to the installation", %{
    provider: provider
  } do
    settings =
      provider.settings
      |> Map.put("ownerConfigMap", "workers")
      |> Map.put("cache", %{"claimTemplate" => provider.settings["storage"]["claimTemplate"]})

    provider = %{provider | settings: settings}

    stub(fn conn ->
      case {conn.method, path(conn)} do
        {"GET", "configmaps/workers"} ->
          Req.Test.json(conn, %{"metadata" => %{"uid" => "owner-uid"}})

        {"GET", "persistentvolumeclaims"} ->
          Req.Test.json(conn, %{"items" => []})

        {"POST", "persistentvolumeclaims"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(body)
          meta = body["metadata"]

          if String.ends_with?(meta["name"], "-cache") do
            assert [%{"uid" => "owner-uid", "kind" => "ConfigMap"}] = meta["ownerReferences"]
          else
            refute Map.has_key?(meta, "ownerReferences")
          end

          assert meta["labels"]["ankole.io/provider"] == "cluster"
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(body)
      end
    end)

    assert :ok = Kubernetes.prepare_storage(provider, @agent)
  end

  test "a cache claim from other cache settings is replaced, and an emptyDir cache removes it", %{
    provider: provider
  } do
    template = provider.settings["storage"]["claimTemplate"]

    provider = %{
      provider
      | settings: Map.put(provider.settings, "cache", %{"claimTemplate" => template})
    }

    cache = ProviderKind.storage_name("prod", @agent) <> "-cache"
    old = put_in(storage_metadata(), ["annotations", "ankole.io/cache-settings"], "old")
    old = %{old | "name" => cache}
    state = start_supervised!({Agent, fn -> %{cache: old, created: nil} end})

    stub(fn conn ->
      case {conn.method, path(conn)} do
        {"GET", "persistentvolumeclaims"} ->
          name = conn.query_params["fieldSelector"] |> String.replace_prefix("metadata.name=", "")
          claim = if name == cache, do: Agent.get(state, & &1.cache)
          Req.Test.json(conn, %{"items" => if(claim, do: [%{"metadata" => claim}], else: [])})

        {"DELETE", "persistentvolumeclaims/" <> ^cache} ->
          Agent.update(state, &%{&1 | cache: nil})
          Req.Test.json(conn, %{"kind" => "Status", "status" => "Success"})

        {"POST", "persistentvolumeclaims"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(body)

          if body["metadata"]["name"] == cache,
            do: Agent.update(state, &%{&1 | cache: body["metadata"], created: body})

          conn |> Plug.Conn.put_status(201) |> Req.Test.json(body)
      end
    end)

    assert :ok = Kubernetes.prepare_storage(provider, @agent)
    created = Agent.get(state, & &1.created)
    settings = created["metadata"]["annotations"]["ankole.io/cache-settings"]
    assert is_binary(settings) and settings != "old"

    # The same settings keep the claim.
    Agent.update(state, &%{&1 | created: nil})
    assert :ok = Kubernetes.prepare_storage(provider, @agent)
    assert Agent.get(state, & &1.created) == nil

    # A cache without a claim template uses emptyDir; the old claim goes.
    provider = %{
      provider
      | settings: Map.put(provider.settings, "cache", %{"sizeLimit" => "5Gi"})
    }

    assert :ok = Kubernetes.prepare_storage(provider, @agent)
    assert Agent.get(state, & &1.cache) == nil
  end

  test "storage preparation refuses a claim owned by another Agent or provider", %{
    provider: provider
  } do
    stub(fn conn ->
      assert path(conn) == "persistentvolumeclaims"

      Req.Test.json(conn, %{
        "items" => [
          %{"metadata" => %{"name" => "foreign", "labels" => %{"ankole.io/provider" => "other"}}}
        ]
      })
    end)

    assert {:error, {:kubernetes_claim_owner_mismatch, _}} =
             Kubernetes.prepare_storage(provider, @agent)
  end

  test "claim deletion waits for finalizers and propagates platform failure", %{
    provider: provider
  } do
    parent = self()

    stub(fn conn ->
      case conn.method do
        "DELETE" ->
          send(parent, :delete_requested)
          Req.Test.json(conn, %{"kind" => "Status", "status" => "Success"})

        "GET" ->
          Req.Test.json(conn, %{
            "items" => [
              %{
                "metadata" =>
                  Map.put(storage_metadata(), "deletionTimestamp", "2026-10-07T00:00:00Z")
              }
            ]
          })
      end
    end)

    assert {:error, {:kubernetes_claim_deleting, _}} = Kubernetes.delete_cache(provider, @agent)
    assert_received :delete_requested
    stub(&status(&1, 500))
    assert {:error, {:kubernetes_api, 500, _}} = Kubernetes.delete_cache(provider, @agent)
  end

  test "deletion refuses another Agent or provider's claim and cleanup Pod", %{provider: provider} do
    for foreign <- [
          put_in(storage_metadata(), ["labels", "ankole.io/provider"], "other"),
          put_in(storage_metadata(), ["annotations", "ankole.io/agent-uid"], "other")
        ] do
      stub(fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"items" => [%{"metadata" => foreign}]})
      end)

      assert {:error, {:kubernetes_claim_owner_mismatch, _}} =
               Kubernetes.delete_cache(provider, @agent)

      assert {:error, {:kubernetes_claim_owner_mismatch, _}} =
               Kubernetes.delete_storage(provider, @agent, nil)

      shared = put_in(provider.settings["storage"], %{"sharedClaim" => "shared"})

      stub(fn conn ->
        assert conn.method == "GET"

        if path(conn) == "persistentvolumeclaims" do
          Req.Test.json(conn, %{"items" => []})
        else
          Req.Test.json(conn, %{"metadata" => foreign, "status" => %{"phase" => "Succeeded"}})
        end
      end)

      assert {:error, {:kubernetes_storage_cleanup_owner_mismatch, _}} =
               Kubernetes.delete_storage(shared, @agent, nil)
    end
  end

  test "a shared cleanup Pod has no Worker probes and reports why it cannot start", %{
    provider: provider
  } do
    provider = put_in(provider.settings["storage"], %{"sharedClaim" => "shared"})

    provider =
      update_in(provider.settings["podTemplate"]["spec"]["containers"], fn [worker] ->
        [Map.put(worker, "livenessProbe", %{"exec" => %{"command" => ["true"]}})]
      end)

    helper = ProviderKind.storage_name("prod", @agent) <> "-storage"
    state = start_supervised!({Agent, fn -> nil end})

    stub(fn conn ->
      case {conn.method, path(conn)} do
        {"GET", "persistentvolumeclaims"} ->
          Req.Test.json(conn, %{"items" => []})

        {"GET", "pods/" <> ^helper} ->
          case Agent.get(state, & &1) do
            nil -> status(conn, 404)
            pod -> Req.Test.json(conn, pod)
          end

        {"POST", "pods"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(body)
          [container] = body["spec"]["containers"]
          refute Map.has_key?(container, "livenessProbe")
          Agent.update(state, fn _ -> Map.put(body, "status", %{"phase" => "Pending"}) end)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(body)

        {"GET", "events"} ->
          Req.Test.json(conn, %{"items" => []})

        {"GET", "pods/" <> _log} ->
          status(conn, 400)
      end
    end)

    assert {:pending, nil} = Kubernetes.delete_storage(provider, @agent, nil)
    # A Pending Pod without a problem is still starting.
    assert {:pending, nil} = Kubernetes.delete_storage(provider, @agent, nil)

    Agent.update(state, fn pod ->
      put_in(pod, ["status"], %{
        "phase" => "Pending",
        "conditions" => [
          %{"type" => "PodScheduled", "reason" => "Unschedulable", "message" => "0/3 nodes"}
        ]
      })
    end)

    assert {:error, {:kubernetes_storage_cleanup_waiting, "0/3 nodes"}} =
             Kubernetes.delete_storage(provider, @agent, nil)
  end

  test "successful shared cleanup completes after requesting Pod deletion", %{provider: provider} do
    provider = put_in(provider.settings["storage"], %{"sharedClaim" => "shared"})
    helper = ProviderKind.storage_name("prod", @agent) <> "-storage"

    stub(fn conn ->
      case {conn.method, path(conn)} do
        {"GET", "persistentvolumeclaims"} ->
          Req.Test.json(conn, %{"items" => []})

        {"GET", "pods/" <> ^helper} ->
          Req.Test.json(conn, %{
            "metadata" =>
              Map.merge(storage_metadata(), %{
                "name" => helper,
                "deletionTimestamp" => "2026-10-07T00:00:00Z",
                "finalizers" => ["ankole.test/retain"]
              }),
            "status" => %{"phase" => "Succeeded"}
          })

        {"DELETE", "pods/" <> ^helper} ->
          assert conn.query_params["gracePeriodSeconds"] == "1"
          Req.Test.json(conn, %{"kind" => "Status", "status" => "Success"})
      end
    end)

    assert {:ok, nil} = Kubernetes.delete_storage(provider, @agent, nil)
  end

  defp storage_metadata do
    metadata("cache")
    |> put_in(["labels", "ankole.io/task"], "storage")
    |> put_in(["labels", "ankole.io/agent"], ProviderKind.hash16(@agent))
  end

  defp stub(fun), do: Req.Test.stub(@cluster, &fun.(Plug.Conn.fetch_query_params(&1)))

  defp path(conn),
    do:
      conn.request_path
      |> String.replace_prefix("/api/v1/namespaces/#{@namespace}/", "")
      |> String.trim_trailing("/")

  defp status(conn, code),
    do:
      conn
      |> Plug.Conn.put_status(code)
      |> Req.Test.json(%{"kind" => "Status", "message" => "platform #{code}"})

  defp name, do: ProviderKind.instance_name("prod", @agent, @generation)
  defp instance, do: %{agent_uid: @agent, generation: @generation, instance_ref: name()}

  defp metadata(name),
    do: %{
      "name" => name,
      "namespace" => @namespace,
      "creationTimestamp" => "2026-10-07T00:00:00Z",
      "labels" => %{
        "ankole.io/installation" => "prod",
        "ankole.io/provider" => "cluster",
        "ankole.io/generation" => @generation
      },
      "annotations" => %{"ankole.io/agent-uid" => @agent}
    }

  defp pod(name, phase, extra \\ %{}),
    do: %{
      "kind" => "Pod",
      "metadata" => Map.merge(metadata(name), extra),
      "status" => %{"phase" => phase}
    }
end
