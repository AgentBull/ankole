defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProvidersTest do
  use Ankole.DataCase, async: false

  alias Ankole.Principals

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{
    Cloudflare,
    Docker,
    Kubernetes,
    Lambda,
    ProviderKind,
    Providers
  }

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{
    Configuration,
    Provider,
    Seed
  }

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  test "every type example satisfies its declared schema" do
    for module <- ProviderKind.all() do
      definition = module.definition()
      assert {:ok, _settings} = Configuration.parse(definition.schema, definition.example)
    end
  end

  test "all providers release idle Workers after fifteen minutes by default" do
    for module <- ProviderKind.all() do
      definition = module.definition()
      assert definition.schema["properties"]["idleReleaseAfter"]["default"] == "15m"
    end
  end

  test "keeps YAML comments and rejects unknown keys with their source path and line" do
    config = "# operator comment\nnetwork: bridge\ncpus: 2\n"
    assert {:ok, provider} = Providers.create(attrs("local", config))
    assert Repo.get!(Provider, provider.id).config == config

    assert {:error, {:invalid_worker_provider_config, errors}} =
             Providers.update("local", %{config: "network: bridge\nenv:\n  HOME: /other\n"})

    assert Enum.any?(errors, &(&1.path == "env.HOME" and &1.line == 3))
    assert Repo.get!(Provider, provider.id).config == config

    assert {:error, {:invalid_worker_provider_config, errors}} =
             Providers.update("local", %{config: "network: bridge\nunknown: true\n"})

    assert Enum.any?(errors, &(&1.path == "unknown" and &1.line == 2))
  end

  test "rejects duplicate keys, non-string keys, and more than one YAML document" do
    for config <- ["cpus: 1\ncpus: 2\n", "1: value\n", "cpus: 1\n---\ncpus: 2\n"] do
      assert {:error, {:invalid_worker_provider_config, [_ | _]}} =
               Providers.create(attrs("invalid", config))
    end

    refute Repo.exists?(Provider)
  end

  test "instance settings include cache, while lifecycle settings do not replace a Worker" do
    definition = Kubernetes.definition()
    assert {:ok, base} = Configuration.parse(definition.schema, definition.example)
    changed = Map.put(base, "cache", %{"sizeLimit" => "2Gi"})

    refute Configuration.digest(definition.schema, changed) ==
             Configuration.digest(definition.schema, base)

    changed = base |> Map.put("idleReleaseAfter", "5m") |> Map.put("stopGraceSeconds", 120)

    assert Configuration.digest(definition.schema, changed) ==
             Configuration.digest(definition.schema, base)
  end

  test "provider settings digests retain the pre-refactor values" do
    for {module, digest} <- [
          {Docker, "7d5aca0bdbed0b444eec2e4ddf6ffaf79e5c82b3a8238074b14f880adec51378"},
          {Kubernetes, "82cdbfebc00ec9e36ba7f743406fc156d326f1d6d441b373f1deb2b25c00ecf4"}
        ] do
      definition = module.definition()
      assert {:ok, settings} = Configuration.parse(definition.schema, definition.example)
      assert Configuration.digest(definition.schema, settings) == digest
    end
  end

  test "provider identity and storage location cannot change" do
    assert {:ok, provider} = Providers.create(attrs("local"))
    assert {:error, changeset} = Providers.update("local", %{provider_id: "another"})
    assert "cannot change after creation" in errors_on(changeset).provider_id
    assert {:error, changeset} = Providers.update("local", %{kind: "cloudflare"})
    assert "cannot change after creation" in errors_on(changeset).kind

    assert {:error, {:invalid_worker_provider_config, [%{path: "socket"}]}} =
             Providers.update("local", %{config: "socket: /other/docker.sock\n"})

    assert Repo.get!(Provider, provider.id).config == provider.config
  end

  test "stores only encrypted credentials, masks them, and keeps an empty update unchanged" do
    attrs = %{
      provider_id: "edge",
      display_name: "Edge",
      kind: "cloudflare",
      config: Cloudflare.definition().example,
      credentials: %{"adapterToken" => "first-secret"}
    }

    assert {:ok, provider} = Providers.create(attrs)
    refute provider.credentials["adapterToken"] == "first-secret"
    assert Providers.projection(provider).credentials == %{"adapterToken" => "********"}
    assert {:ok, loaded} = Providers.load(provider)
    assert loaded.secrets == %{"adapterToken" => "first-secret"}

    # The ciphertext is bound to its provider row and credential name.
    for {id, name} <- [
          {Ankole.Ecto.UUIDv7.autogenerate(), "adapterToken"},
          {provider.id, "anotherKey"}
        ] do
      assert {:error, _reason} =
               Ankole.SecretKeyBase.unseal(
                 provider.credentials["adapterToken"],
                 "worker_provider_credential",
                 ["worker_providers", id, name]
               )
    end

    assert {:ok, provider} = Providers.update("edge", %{credentials: %{"adapterToken" => ""}})
    assert {:ok, loaded} = Providers.load(provider)
    assert loaded.secrets["adapterToken"] == "first-secret"

    assert {:ok, provider} =
             Providers.update("edge", %{credentials: %{"adapterToken" => "replacement-secret"}})

    assert {:ok, loaded} = Providers.load(provider)
    assert loaded.secrets["adapterToken"] == "replacement-secret"
  end

  test "a stored invalid configuration makes only that provider unavailable" do
    assert {:ok, broken} = Providers.create(attrs("broken"))
    assert {:ok, healthy} = Providers.create(attrs("healthy"))
    Repo.update_all(where(Provider, id: ^broken.id), set: [config: "cpus: wrong\n"])
    assert {:error, {:invalid_worker_provider_config, [_ | _]}} = Providers.load("broken")
    assert {:ok, %{provider_id: "healthy"}} = Providers.load(healthy)
    assert {:ok, repaired} = Providers.update("broken", %{config: "cpus: 2\n"})
    assert {:ok, %{settings: %{"cpus" => 2}}} = Providers.load(repaired)
  end

  test "Agent creation selects its explicit provider or default and fails atomically without one" do
    owner = Ankole.PrincipalsFixtures.human_fixture().principal.uid

    agent_attrs = %{
      handle: "needs-provider",
      display_name: "Agent",
      role: "Research",
      owner_principal_uid: owner
    }

    assert {:error, :worker_provider_required} = Principals.create_agent(agent_attrs)
    refute Repo.get_by(Ankole.Principals.Agent, handle: "needs-provider")
    refute Repo.exists?(AgentWorker)

    assert {:ok, _provider} = Providers.create(Map.put(attrs("default"), :is_default, true))
    assert {:ok, _provider} = Providers.create(attrs("explicit"))
    assert {:ok, %{principal: first}} = Principals.create_agent(agent_attrs)
    assert Repo.get!(AgentWorker, first.uid).provider_id == "default"

    assert {:ok, %{principal: second}} =
             Principals.create_agent(
               %{agent_attrs | handle: "explicit-agent"}
               |> Map.put(:worker_provider_id, "explicit")
             )

    assert Repo.get!(AgentWorker, second.uid).provider_id == "explicit"
  end

  test "site provider changes reach both tenants and a foreign tenant Worker prevents deletion",
       %{tenant: tenant} do
    assert {:ok, provider} = Providers.create(attrs("shared"))

    other =
      Repo.insert!(%Ankole.Tenants.Tenant{
        slug: "other-" <> Ecto.UUID.generate(),
        display_name: "Other"
      })

    own =
      Repo.insert!(%AgentWorker{
        agent_uid: Ecto.UUID.generate(),
        provider_id: provider.provider_id
      })

    foreign =
      Repo.with_tenant(other.id, fn ->
        Repo.insert!(%AgentWorker{
          agent_uid: Ecto.UUID.generate(),
          provider_id: provider.provider_id
        })
      end)

    assert [%{agent_count: 2}] = Providers.list_projections()
    assert Providers.projection(provider).agent_count == 2
    assert {:ok, _} = Providers.update(provider.provider_id, %{display_name: "Shared provider"})
    jobs = all_enqueued(worker: Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob)

    assert Enum.any?(
             jobs,
             &(&1.args["agent_uid"] == own.agent_uid and &1.args["tenant_id"] == tenant.id)
           )

    assert Enum.any?(
             jobs,
             &(&1.args["agent_uid"] == foreign.agent_uid and &1.args["tenant_id"] == other.id)
           )

    Repo.delete!(own)
    assert {:error, :worker_provider_in_use} = Providers.delete(provider.provider_id)
    assert Repo.get!(Provider, provider.id)
    Repo.with_tenant(other.id, fn -> Repo.delete!(foreign) end)
    assert {:ok, _} = Providers.delete(provider.provider_id)
  end

  test "an assignment is permanent and deletion waits for every Worker row" do
    assert {:ok, _provider} = Providers.create(attrs("local"))
    Repo.insert!(%AgentWorker{agent_uid: "legacy"})
    assert {:ok, %{provider_id: "local"}} = Providers.assign("legacy", "local")
    assert {:error, :worker_provider_immutable} = Providers.assign("legacy", "local")
    assert [%{agent_count: 1}] = Providers.list_projections()
    Repo.update_all(AgentWorker, set: [state: "deleting"])
    assert {:error, :worker_provider_in_use} = Providers.delete("local")
    Repo.delete_all(AgentWorker)
    assert {:ok, _provider} = Providers.delete("local")
  end

  test "seed insertion and legacy assignment commit together, then ignore the seed file" do
    Repo.insert!(%AgentWorker{agent_uid: "legacy"})
    Repo.insert!(%AgentWorker{agent_uid: "deleted", state: "deleting"})
    other = create_tenant()
    Repo.with_tenant(other.id, fn -> Repo.insert!(%AgentWorker{agent_uid: "foreign-legacy"}) end)
    first = attrs("local") |> Map.put(:legacy_agents, true) |> Map.put(:is_default, true)
    path = seed_file([first, attrs("invalid", "cpus: wrong\n")])
    assert {:error, _reason} = Repo.without_tenant(fn -> Seed.import_file(path) end)
    refute Repo.exists?(Provider)
    assert Repo.get!(AgentWorker, "legacy").provider_id == nil

    assert Repo.with_tenant(other.id, fn ->
             Repo.get!(AgentWorker, "foreign-legacy").provider_id
           end) == nil

    File.write!(path, Ankole.JSON.encode!(%{providers: [first]}))
    assert :ok = Repo.without_tenant(fn -> Seed.import_file(path) end)
    assert Repo.get!(AgentWorker, "legacy").provider_id == "local"

    assert Repo.with_tenant(other.id, fn ->
             Repo.get!(AgentWorker, "foreign-legacy").provider_id
           end) == "local"

    assert Repo.get!(AgentWorker, "deleted").provider_id == nil
    File.rm!(path)
    assert :ok = Repo.without_tenant(fn -> Seed.import_file(path) end)
    assert [%{provider_id: "local"}] = Providers.list()
  end

  test "a provider ID must be a label value on every platform" do
    for id <- [
          "",
          "Local",
          "1local",
          "-local",
          "local-",
          "lo_cal",
          "lo.cal",
          String.duplicate("a", 64)
        ] do
      assert {:error, changeset} = Providers.create(attrs(id))
      assert "has invalid format" in errors_on(changeset).provider_id
    end

    refute Repo.exists?(Provider)

    for id <- ["a", "a1", "local-docker", String.duplicate("a", 63)] do
      assert {:ok, _provider} = Providers.create(attrs(id))
    end
  end

  test "null removes an optional credential, and an empty or absent value keeps it" do
    assert {:ok, _provider} =
             Providers.create(%{
               provider_id: "aws",
               display_name: "AWS",
               kind: "lambda",
               config: Lambda.definition().example,
               credentials: %{
                 "accessKeyId" => "AKIAEXAMPLE",
                 "secretAccessKey" => "first-secret",
                 "sessionToken" => "first-session"
               }
             })

    # Long-term keys must not send the session token of the earlier keys.
    assert {:ok, provider} =
             Providers.update("aws", %{
               credentials: %{"secretAccessKey" => "", "sessionToken" => nil}
             })

    assert {:ok, loaded} = Providers.load(provider)

    assert loaded.secrets == %{
             "accessKeyId" => "AKIAEXAMPLE",
             "secretAccessKey" => "first-secret"
           }

    assert {:error, {:invalid_worker_provider_credentials, _message}} =
             Providers.update("aws", %{credentials: %{"accessKeyId" => nil}})

    # Without a key pair, the provider uses the default AWS credential chain.
    assert {:ok, provider} =
             Providers.update("aws", %{
               credentials: %{"accessKeyId" => nil, "secretAccessKey" => nil}
             })

    assert provider.credentials == %{}
    assert {:ok, loaded} = Providers.load(provider)
    assert loaded.secrets == %{}

    assert {:ok, _provider} =
             Providers.create(%{
               provider_id: "edge",
               display_name: "Edge",
               kind: "cloudflare",
               config: Cloudflare.definition().example,
               credentials: %{"adapterToken" => "adapter-secret"}
             })

    assert {:error, {:invalid_worker_provider_credential, "adapterToken"}} =
             Providers.update("edge", %{credentials: %{"adapterToken" => nil}})

    assert {:ok, %{secrets: %{"adapterToken" => "adapter-secret"}}} = Providers.load("edge")
  end

  test "a kubeconfig keeps its cluster and its in-cluster or remote access" do
    config =
      Kubernetes.definition().example <>
        """
        endpoints:
          runtimeFabricUrl: wss://ankole.example.test/runtime-fabric/worker
          relayOrigin: https://ankole.example.test
          aiGatewayUrl: https://ankole.example.test/api/v1/ai-gateway
        """

    assert {:ok, _provider} =
             Providers.create(%{
               provider_id: "remote",
               display_name: "Remote",
               kind: "kubernetes",
               config: config,
               credentials: %{
                 "kubeconfig" => kubeconfig("https://a.example.test", "ca-a", "token-a")
               }
             })

    assert {:ok, provider} =
             Providers.update("remote", %{
               credentials: %{
                 "kubeconfig" => kubeconfig("https://a.example.test", "ca-a", "token-b")
               }
             })

    assert {:ok, loaded} = Providers.load(provider)
    assert loaded.secrets["kubeconfig"] =~ "token-b"

    for changed <- [
          kubeconfig("https://b.example.test", "ca-a", "token-b"),
          kubeconfig("https://a.example.test", "ca-b", "token-b"),
          nil
        ] do
      assert {:error, :worker_provider_cluster_immutable} =
               Providers.update("remote", %{credentials: %{"kubeconfig" => changed}})
    end

    assert {:error, :invalid_worker_provider_kubeconfig} =
             Providers.update("remote", %{credentials: %{"kubeconfig" => "clusters: ["}})

    assert {:ok, _provider} =
             Providers.create(%{
               provider_id: "in-cluster",
               display_name: "In cluster",
               kind: "kubernetes",
               config: config
             })

    assert {:error, :worker_provider_cluster_immutable} =
             Providers.update("in-cluster", %{
               credentials: %{
                 "kubeconfig" => kubeconfig("https://a.example.test", "ca-a", "token-a")
               }
             })
  end

  test "remote credentials reject an owner ConfigMap before checking endpoints" do
    assert {:error,
            {:invalid_worker_provider_config,
             [
               %{
                 path: "ownerConfigMap",
                 line: nil,
                 message: "is only available with the in-cluster ServiceAccount"
               }
             ]}} =
             Providers.create(%{
               provider_id: "remote-owner",
               display_name: "Remote owner",
               kind: "kubernetes",
               config: Kubernetes.definition().example <> "ownerConfigMap: owner\n",
               credentials: %{
                 "kubeconfig" => kubeconfig("https://cluster.example.test", "ca", "token")
               }
             })
  end

  test "remote credentials require all three endpoints" do
    assert {:error,
            {:invalid_worker_provider_config,
             [
               %{
                 path: "endpoints",
                 line: nil,
                 message: "all three endpoints are required for a remote cluster"
               }
             ]}} =
             Providers.create(%{
               provider_id: "remote-addresses",
               display_name: "Remote addresses",
               kind: "kubernetes",
               config: Kubernetes.definition().example,
               credentials: %{
                 "kubeconfig" => kubeconfig("https://cluster.example.test", "ca", "token")
               }
             })
  end

  test "file certificate authority bytes are frozen before credential encryption" do
    path =
      Path.join(System.tmp_dir!(), "ankole-provider-ca-#{System.unique_integer([:positive])}")

    File.write!(path, "frozen CA bytes")
    on_exit(fn -> File.rm(path) end)

    config =
      Kubernetes.definition().example <>
        """
        endpoints:
          runtimeFabricUrl: wss://ankole.example.test/runtime-fabric/worker
          relayOrigin: https://ankole.example.test
          aiGatewayUrl: https://ankole.example.test/api/v1/ai-gateway
        """

    credentials =
      kubeconfig("https://cluster.example.test", "ca", "token")
      |> String.replace(
        "certificate-authority-data: #{Base.encode64("ca")}",
        "certificate-authority: #{path}"
      )

    assert {:ok, provider} =
             Providers.create(%{
               provider_id: "remote-file-ca",
               display_name: "Remote CA",
               kind: "kubernetes",
               config: config,
               credentials: %{"kubeconfig" => credentials}
             })

    File.write!(path, "different CA bytes")
    assert {:ok, loaded} = Providers.load(provider)

    {:ok, stored, _locations} =
      Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.YAML.parse(
        loaded.secrets["kubeconfig"]
      )

    [cluster] = stored["clusters"]
    assert cluster["cluster"]["certificate-authority-data"] == Base.encode64("frozen CA bytes")
    refute Map.has_key?(cluster["cluster"], "certificate-authority")
  end

  test "seed credentials come from an environment variable or a file, and a missing source stops startup" do
    unique = System.unique_integer([:positive])
    variable = "ANKOLE_TEST_WORKER_ADAPTER_TOKEN_#{unique}"
    token_file = Path.join(System.tmp_dir!(), "worker-adapter-token-#{unique}")
    previous = Application.get_env(:ankole, :worker_providers_file)

    edge = fn id, source ->
      %{
        provider_id: id,
        display_name: id,
        kind: "cloudflare",
        config: Cloudflare.definition().example,
        credentials: %{"adapterToken" => source}
      }
    end

    path =
      seed_file([edge.("from-env", %{env: variable}), edge.("from-file", %{file: token_file})])

    Application.put_env(:ankole, :worker_providers_file, path)

    on_exit(fn ->
      System.delete_env(variable)
      File.rm(token_file)

      if previous,
        do: Application.put_env(:ankole, :worker_providers_file, previous),
        else: Application.delete_env(:ankole, :worker_providers_file)
    end)

    missing =
      {:error,
       {:worker_providers_seed_failed, {:worker_provider_seed_secret_missing, "adapterToken"}}}

    assert Seed.start_link([]) == missing
    System.put_env(variable, "env-token")
    assert Seed.start_link([]) == missing
    refute Repo.exists?(Provider)
    File.write!(token_file, "file-token")
    assert Seed.start_link([]) == :ignore
    assert {:ok, %{secrets: %{"adapterToken" => "env-token"}}} = Providers.load("from-env")
    assert {:ok, %{secrets: %{"adapterToken" => "file-token"}}} = Providers.load("from-file")
  end

  defp kubeconfig(server, ca, token) do
    """
    apiVersion: v1
    kind: Config
    current-context: remote
    clusters:
      - name: remote
        cluster:
          server: #{server}
          certificate-authority-data: #{Base.encode64(ca)}
    users:
      - name: worker
        user:
          token: #{token}
    contexts:
      - name: remote
        context:
          cluster: remote
          user: worker
    """
  end

  defp attrs(id, config \\ Docker.definition().example),
    do: %{provider_id: id, display_name: id, kind: "docker", config: config}

  defp seed_file(providers) do
    path =
      Path.join(
        System.tmp_dir!(),
        "worker-provider-seed-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, Ankole.JSON.encode!(%{providers: providers}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
