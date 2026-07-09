defmodule Ankole.ActorRuntime.WorkerBootstrapTest do
  use Ankole.DataCase, async: false

  alias Ankole.ActorRuntime.WorkerAuthKey
  alias Ankole.ActorRuntime.WorkerBootstrap
  alias Ankole.ActorRuntime.WorkerBootstrap.Docker
  alias Ankole.ActorRuntime.WorkerBootstrap.Spec

  describe "container_spec/1" do
    test "describes the shared Agent Computer Docker runtime without inventing worker state" do
      assert {:ok,
              %Spec{
                contract_version: 2,
                kind: :container,
                image: "ankole-agent-computer:0.1.0",
                docker: %{
                  cap_add: ["SYS_ADMIN"],
                  security_opts: ["seccomp=unconfined", "systempaths=unconfined"],
                  extra_hosts: []
                },
                env: %{},
                host_setup_dirs: [],
                mounts: []
              }} =
               WorkerBootstrap.container_spec(image: "ankole-agent-computer:0.1.0")
    end
  end

  describe "worker_spec/1" do
    test "adds canonical auth, connectivity, and workspace guarantees" do
      workspace_root = "/tmp/ankole worker"

      assert {:ok,
              %Spec{
                contract_version: 2,
                kind: :worker,
                image: "ankole-agent-computer:0.1.0",
                docker: %{
                  cap_add: ["SYS_ADMIN"],
                  security_opts: ["seccomp=unconfined", "systempaths=unconfined"],
                  extra_hosts: [
                    %{host: "host.docker.internal", address: "host-gateway"}
                  ]
                },
                env: %{
                  "WORKER_ID" => "worker-a",
                  "RUNTIME_FABRIC_URL" => runtime_fabric_url
                },
                host_setup_dirs: [
                  "/tmp/ankole worker/shared/user-files",
                  "/tmp/ankole worker/shared/skills/agents",
                  "/tmp/ankole worker/sessions"
                ],
                mounts: [
                  %{
                    source: "/tmp/ankole worker/shared",
                    target: "/workspace/shared",
                    readonly: false
                  },
                  %{
                    source: "/tmp/ankole worker/sessions",
                    target: "/workspace/.sessions",
                    readonly: false
                  }
                ]
              } = spec} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://host.docker.internal:6010",
                 worker_id: "worker-a",
                 auth_key: "secret with / symbols",
                 image: "ankole-agent-computer:0.1.0",
                 workspace_root: workspace_root
               )

      assert runtime_fabric_url ==
               "tcp://:secret+with+%2F+symbols@host.docker.internal:6010"

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
               "RUNTIME_FABRIC_URL=tcp://:secret+with+%2F+symbols@host.docker.internal:6010",
               "-e",
               "WORKER_ID=worker-a",
               "--mount",
               "type=bind,src=/tmp/ankole worker/shared,dst=/workspace/shared",
               "--mount",
               "type=bind,src=/tmp/ankole worker/sessions,dst=/workspace/.sessions",
               "ankole-agent-computer:0.1.0"
             ]

      shell = Docker.shell_command(spec)
      assert shell =~ "mkdir -p '/tmp/ankole worker/shared/user-files'"
      assert shell =~ "'type=bind,src=/tmp/ankole worker/shared,dst=/workspace/shared'"

      assert_raise ArgumentError, ~r/cannot replace canonical environment/, fn ->
        Docker.argv(spec, additional_env: %{"WORKER_ID" => "adapter-worker"})
      end
    end

    test "resolves the persisted AppConfigure auth key when no explicit key is passed" do
      assert {:ok, auth_key} = WorkerAuthKey.ensure()

      assert {:ok, %Spec{env: %{"RUNTIME_FABRIC_URL" => runtime_fabric_url}}} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-app-config",
                 workspace_root: "/tmp/ankole-worker"
               )

      assert runtime_fabric_url ==
               "tcp://:#{URI.encode_www_form(auth_key)}@127.0.0.1:6010"
    end

    test "rejects invalid or incomplete worker inputs" do
      assert {:error, {:missing, :workspace_root}} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 auth_key: "secret"
               )

      assert {:error, {:invalid, :auth_key}} =
               WorkerBootstrap.worker_spec(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 auth_key: "",
                 workspace_root: "/tmp/ankole-worker"
               )

      assert {:error, :invalid_runtime_fabric_endpoint} =
               WorkerBootstrap.worker_spec(
                 endpoint: "http://127.0.0.1:6010",
                 worker_id: "worker-a",
                 auth_key: "secret",
                 workspace_root: "/tmp/ankole-worker"
               )
    end
  end
end
