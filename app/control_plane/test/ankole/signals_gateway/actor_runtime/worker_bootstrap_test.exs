defmodule Ankole.SignalsGateway.ActorRuntime.WorkerBootstrapTest do
  use Ankole.DataCase, async: false

  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.Docker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.Spec

  describe "container_spec/1" do
    test "describes the shared Agent Computer Docker runtime without inventing worker state" do
      assert {:ok,
              %Spec{
                contract_version: 3,
                kind: :container,
                image: "ankole-agent-computer:test",
                docker: %{
                  cap_add: ["SYS_ADMIN"],
                  security_opts: ["seccomp=unconfined", "systempaths=unconfined"],
                  extra_hosts: []
                },
                env: %{},
                host_setup_dirs: [],
                mounts: []
              }} =
               WorkerBootstrap.container_spec(image: "ankole-agent-computer:test")
    end

    test "uses only the release-paired image configured by the control-plane image" do
      previous = System.get_env("ANKOLE_AGENT_COMPUTER_IMAGE")

      on_exit(fn ->
        if previous,
          do: System.put_env("ANKOLE_AGENT_COMPUTER_IMAGE", previous),
          else: System.delete_env("ANKOLE_AGENT_COMPUTER_IMAGE")
      end)

      System.delete_env("ANKOLE_AGENT_COMPUTER_IMAGE")
      assert {:error, {:invalid, :image}} = WorkerBootstrap.container_spec()

      revision = String.duplicate("a", 40)
      image = "ghcr.io/agentbull/ankole-agent-computer-worker:#{revision}"
      System.put_env("ANKOLE_AGENT_COMPUTER_IMAGE", image)

      assert {:ok, %Spec{image: ^image}} = WorkerBootstrap.container_spec()
    end
  end

  describe "worker_spec/1" do
    test "adds canonical auth, connectivity, and Agent Home guarantees" do
      agents_root = "/tmp/ankole agents"

      assert {:ok,
              %Spec{
                contract_version: 3,
                kind: :worker,
                image: "ankole-agent-computer:test",
                docker: %{
                  cap_add: ["SYS_ADMIN"],
                  security_opts: ["seccomp=unconfined", "systempaths=unconfined"],
                  extra_hosts: [
                    %{host: "host.docker.internal", address: "host-gateway"}
                  ]
                },
                env: %{
                  "ANKOLE_AGENTS_ROOT" => "/agents",
                  "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => "tcp://host.docker.internal:6010",
                  "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "secret with / symbols",
                  "WORKER_ID" => "worker-a"
                },
                host_setup_dirs: ["/tmp/ankole agents"],
                mounts: [
                  %{
                    source: "/tmp/ankole agents",
                    target: "/agents",
                    readonly: false
                  }
                ]
              } = spec} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://host.docker.internal:6010",
                 worker_id: "worker-a",
                 auth_key: "secret with / symbols",
                 image: "ankole-agent-computer:test",
                 agents_root: agents_root
               )

      assert Docker.argv(spec) == [
               "run",
               "--rm",
               "--cap-add",
               "SYS_ADMIN",
               "--security-opt",
               "seccomp=unconfined",
               "--security-opt",
               "systempaths=unconfined",
               "--add-host",
               "host.docker.internal=host-gateway",
               "-e",
               "ANKOLE_AGENTS_ROOT=/agents",
               "-e",
               "ANKOLE_RUNTIME_FABRIC_ENDPOINT=tcp://host.docker.internal:6010",
               "-e",
               "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=secret with / symbols",
               "-e",
               "WORKER_ID=worker-a",
               "--mount",
               "type=bind,src=/tmp/ankole agents,dst=/agents",
               "ankole-agent-computer:test"
             ]

      shell = Docker.shell_command(spec)
      assert shell =~ "mkdir -p '/tmp/ankole agents'"
      assert shell =~ "'type=bind,src=/tmp/ankole agents,dst=/agents'"

      assert_raise ArgumentError, ~r/cannot replace canonical environment/, fn ->
        Docker.argv(spec, additional_env: %{"WORKER_ID" => "adapter-worker"})
      end
    end

    test "resolves the persisted AppConfigure auth key when no explicit key is passed" do
      assert {:ok, auth_key} = WorkerAuthKey.ensure()

      assert {:ok,
              %Spec{
                env: %{
                  "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => "tcp://127.0.0.1:6010",
                  "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => ^auth_key
                }
              }} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-app-config",
                 image: "ankole-agent-computer:test",
                 agents_root: "/tmp/ankole-agents"
               )
    end

    test "rejects invalid or incomplete worker inputs" do
      assert {:error, {:missing, :agents_root}} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 image: "ankole-agent-computer:test",
                 auth_key: "secret"
               )

      assert {:error, {:invalid, :auth_key}} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 image: "ankole-agent-computer:test",
                 auth_key: "",
                 agents_root: "/tmp/ankole-agents"
               )

      assert {:error, {:missing, :endpoint}} =
               WorkerBootstrap.worker_spec(
                 worker_id: "worker-a",
                 image: "ankole-agent-computer:test",
                 auth_key: "secret",
                 agents_root: "/tmp/ankole-agents"
               )
    end
  end
end
