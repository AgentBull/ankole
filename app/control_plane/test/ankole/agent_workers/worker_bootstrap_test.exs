defmodule Ankole.AgentWorkers.WorkerBootstrapTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.WorkerBootstrap
  alias Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec

  describe "agent_worker_spec/5" do
    test "binds the generation and credential to the Agent's persistent storage" do
      provider = %Provider{
        kind: "docker",
        settings: %{},
        runtime: %{
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

      assert map_size(spec.env) == 4
      refute inspect(spec) =~ "token-a"

      assert Enum.sort(WorkerBootstrap.contract_env_names()) ==
               Enum.sort(~w(WORKER_ID ANKOLE_RUNTIME_FABRIC_ENDPOINT
                 ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY ANKOLE_WORKER_STORAGE
                 ANKOLE_WORKER_TASK ANKOLE_WORKER_NFS_SOURCE ANKOLE_WORKER_BOOTSTRAP
                 ANKOLE_WORKER_ADAPTER_URL HOME CODEX_HOME CODEX_SQLITE_HOME))
    end
  end

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
