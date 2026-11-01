defmodule Ankole.AgentWorkers.WorkerBootstrapTest do
  use ExUnit.Case, async: false

  alias Ankole.AgentWorkers.WorkerBootstrap
  alias Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec

  @tenant "019a3767-3400-7000-8000-000000000001"

  setup do
    Ankole.Repo.put_tenant_id(@tenant)
    previous_version = System.get_env("ANKOLE_VERSION")
    previous_env = System.get_env("ANKOLE_ENV")
    System.delete_env("ANKOLE_VERSION")
    System.delete_env("ANKOLE_ENV")

    on_exit(fn ->
      restore_env("ANKOLE_VERSION", previous_version)
      restore_env("ANKOLE_ENV", previous_env)
    end)

    :ok
  end

  describe "agent_worker_spec/5" do
    test "equal Agent names keep separate storage in different tenants" do
      provider = %{
        settings: %{},
        runtime: %{
          installation: "test",
          image: "worker:1",
          runtime_fabric_endpoint: "ws://worker"
        }
      }

      first =
        WorkerBootstrap.agent_worker_spec(
          provider,
          "owner+work@example.com_assistant",
          "gen1",
          "token-a"
        )

      other_tenant = "019a3767-3400-7000-8000-000000000002"

      second =
        Ankole.Repo.with_tenant(other_tenant, fn ->
          WorkerBootstrap.agent_worker_spec(provider, first.agent_uid, "gen1", "token-b")
        end)

      assert first.env["WORKER_ID"] == second.env["WORKER_ID"]
      assert first.tenant_id == @tenant
      assert second.tenant_id == other_tenant
      refute first.env["ANKOLE_WORKER_STORAGE_NAME"] == second.env["ANKOLE_WORKER_STORAGE_NAME"]
      assert first.env["ANKOLE_WORKER_STORAGE_NAME"] =~ ~r/^ankole-test-[0-9a-f]{16}$/
    end

    test "binds the generation and credential to the Agent's persistent storage" do
      provider = %{
        kind: "docker",
        settings: %{},
        runtime: %{
          installation: "test",
          image: "ankole-agent-computer:2",
          runtime_fabric_endpoint: "ws://control-plane:4000/runtime-fabric/worker"
        }
      }

      storage_ref = %{"volume" => "agent-a-home"}

      spec =
        WorkerBootstrap.agent_worker_spec(
          provider,
          "agent-a",
          "gen0000001",
          "token-a",
          storage_ref
        )

      assert %AgentWorkerSpec{
               tenant_id: @tenant,
               agent_uid: "agent-a",
               generation: "gen0000001",
               image: "ankole-agent-computer:2",
               storage_ref: ^storage_ref,
               env: %{
                 "WORKER_ID" => "agent-a",
                 "ANKOLE_RUNTIME_FABRIC_ENDPOINT" =>
                   "ws://control-plane:4000/runtime-fabric/worker",
                 "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "token-a",
                 "ANKOLE_WORKER_STORAGE" => "mounted"
               }
             } = spec

      assert spec.env["ANKOLE_WORKER_TENANT_ID"] == @tenant

      assert spec.env["ANKOLE_WORKER_STORAGE_NAME"] ==
               Ankole.AgentWorkers.ProviderKind.storage_name("test", "agent-a")

      assert map_size(spec.env) == 6
      refute inspect(spec) =~ "token-a"

      assert Enum.sort(WorkerBootstrap.contract_env_names()) ==
               Enum.sort(
                 ~w(WORKER_ID ANKOLE_WORKER_TENANT_ID ANKOLE_WORKER_STORAGE_NAME ANKOLE_RUNTIME_FABRIC_ENDPOINT
                 ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY ANKOLE_WORKER_STORAGE
                 ANKOLE_WORKER_TASK ANKOLE_WORKER_NFS_SOURCE ANKOLE_WORKER_BOOTSTRAP
                 ANKOLE_WORKER_ADAPTER_URL ANKOLE_VERSION ANKOLE_ENV
                 HOME CODEX_HOME CODEX_SQLITE_HOME)
               )
    end

    test "forwards non-blank ANKOLE_VERSION and ANKOLE_ENV from the control plane" do
      System.put_env("ANKOLE_VERSION", "v2.0.0")
      System.put_env("ANKOLE_ENV", "prod")

      provider = %{
        kind: "docker",
        settings: %{},
        runtime: %{
          installation: "test",
          image: "ankole-agent-computer:2",
          runtime_fabric_endpoint: "ws://control-plane:4000/runtime-fabric/worker"
        }
      }

      spec = WorkerBootstrap.agent_worker_spec(provider, "agent-a", "gen0000001", "token-a")

      assert spec.env["ANKOLE_VERSION"] == "v2.0.0"
      assert spec.env["ANKOLE_ENV"] == "prod"
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  test "Skill directories use the three Worker library roots" do
    for {source, kind, expected} <- [
          {"builtin", "builtin", "/repo/app/library/skills/example"},
          {"builtin", "internal", "/repo/internals/skills/skills/example"},
          {"installed", nil, "/workspace/installed-skills/skills/example"}
        ] do
      assert WorkerBootstrap.skill_directory(%{
               "source_kind" => source,
               "skill_root" => kind,
               "relative_path" => "skills/example"
             }) == expected
    end
  end
end
