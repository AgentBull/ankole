defmodule Ankole.ComposeAgentHomeMigrationIntegrationTest do
  use ExUnit.Case, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Docker, ProviderKind}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{Configuration, Provider}
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @moduletag timeout: 180_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external
  @compose Path.expand("../../../tools/deploy/docker-compose/compose.yaml", __DIR__)

  test "the Compose migration stops a paused legacy writer, copies Home, and never overwrites a completed copy" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    project = "wp-mig-#{System.unique_integer([:positive])}"
    legacy = project <> "_agents_data"
    uid = "legacy-agent"
    old = project <> "-old-worker"
    home = ProviderKind.storage_name(project, uid)
    env = migration_env(project)
    provider = docker_provider(project, image)

    on_exit(fn ->
      assert {:ok, true} =
               wait_until(deadline(30_000), fn ->
                 assert {:ok, instances} = Docker.list_instances(provider, uid)

                 for instance <- instances,
                     do: assert(:ok = Docker.delete_instance(provider, instance, :now))

                 instances == []
               end)

      docker!(["compose", "-f", @compose, "-p", project, "down", "-v"], env)
      docker!(["stop", "--time", "1", old])
      docker!(["rm", old])
      assert {:ok, nil} = Docker.delete_storage(provider, uid, nil)
      docker!(["volume", "rm", legacy])
    end)

    config =
      docker!(["compose", "-f", @compose, "-p", project, "config", "--format", "json"], env)
      |> Ankole.JSON.decode!()

    assert get_in(config, [
             "services",
             "control-plane",
             "depends_on",
             "migrate-agent-homes",
             "condition"
           ]) == "service_completed_successfully"

    start_database!(project, env, [uid])
    docker!(["volume", "create", legacy])

    docker!([
      "run",
      "-d",
      "--name",
      old,
      "--mount",
      "type=volume,source=#{legacy},target=/agents",
      "--entrypoint",
      "sh",
      "docker:29-cli",
      "-ec",
      "mkdir -m 700 /agents/#{uid}; printf old > /agents/#{uid}/keep; trap 'printf drained > /agents/#{uid}/drained; exit 0' TERM; while :; do sleep 1; done"
    ])

    assert {:ok, true} =
             wait_until(deadline(10_000), fn ->
               {_output, status} =
                 System.cmd("docker", ["exec", old, "test", "-f", "/agents/#{uid}/keep"],
                   stderr_to_stdout: true
                 )

               status == 0
             end)

    docker!(["pause", old])
    run_migration(project, env)
    assert String.trim(docker!(["inspect", "--format", "{{.State.Running}}", old])) == "false"
    assert :ok = Docker.prepare_storage(provider, uid)
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, "migrated", "migration-test")
    assert {:ok, nil} = Docker.create_instance(provider, spec)
    name = ProviderKind.instance_name(project, uid, "migrated")

    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               {_output, status} =
                 System.cmd(
                   "docker",
                   ["exec", "--user", "1000:1000", name, "test", "-L", "/agents/#{uid}"],
                   stderr_to_stdout: true
                 )

               status == 0
             end)

    assert docker!([
             "exec",
             "--user",
             "1000:1000",
             name,
             "sh",
             "-ec",
             "test \"$(stat -c %u /workspace)\" = 1000; cat /workspace/keep /agents/#{uid}/drained; printf new > /workspace/keep"
           ]) == "olddrained"

    run_migration(project, env)
    assert docker!(["exec", "--user", "1000:1000", name, "cat", "/workspace/keep"]) == "new"
    assert String.trim(docker!(["volume", "inspect", "--format", "{{.Name}}", home])) == home
    assert String.trim(docker!(["volume", "inspect", "--format", "{{.Name}}", legacy])) == legacy
  end

  test "a rerun of the Compose migration completes a partial copy and skips deleted Agents" do
    project = "wp-mig-#{System.unique_integer([:positive])}"
    legacy = project <> "_agents_data"
    uid = "legacy-agent"
    deleted = "deleted-agent"
    home = ProviderKind.storage_name(project, uid)
    env = migration_env(project)
    # The migration does not start a Worker, so no image is needed.
    provider = docker_provider(project, nil)

    on_exit(fn ->
      docker!(["compose", "-f", @compose, "-p", project, "down", "-v"], env)
      assert {:ok, nil} = Docker.delete_storage(provider, uid, nil)
      docker!(["volume", "rm", legacy])
    end)

    # The old release kept the Home of an Agent that it deleted.
    start_database!(project, env, [uid])

    # The old Worker ran as root and kept the Home at mode 0700.
    docker!(["volume", "create", legacy])

    in_volumes!(
      [{legacy, "/source"}],
      "mkdir -m 700 /source/#{uid} /source/#{deleted}; mkdir /source/#{uid}/nested; printf old > /source/#{uid}/keep; printf nested > /source/#{uid}/nested/data; printf private > /source/#{deleted}/keep"
    )

    # The interrupted run created the target volume and copied part of one
    # file. It stopped before it changed the owner and wrote the marker.
    assert :ok = Docker.prepare_storage(provider, uid)
    in_volumes!([{home, "/target"}], "printf ol > /target/keep")

    assert run_migration(project, env) =~ "Skipped the Home of a deleted Agent: #{deleted}"

    assert docker!(["volume", "ls", "-q", "--filter", "label=ankole.agent-uid=#{deleted}"]) ==
             ""

    assert in_volumes!(
             [{home, "/target"}],
             "stat -c '%u %n' /target /target/keep /target/nested /target/nested/data; cat /target/keep /target/nested/data"
           ) ==
             "1000 /target\n1000 /target/keep\n1000 /target/nested\n1000 /target/nested/data\noldnested"

    assert in_volumes!(
             [{legacy, "/source"}],
             "cat /source/.ankole-worker-provider-migration/#{uid}"
           ) == home <> "\n"
  end

  # The migration copies only the Homes of the Agents in the database. The
  # table has only the column that the migration reads.
  defp start_database!(project, env, uids) do
    compose = ["compose", "-f", @compose, "-p", project]
    docker!(compose ++ ["up", "-d", "--wait", "postgresql"], env)
    values = Enum.map_join(uids, ",", &"('#{&1}')")

    docker!(
      compose ++
        ~w(exec -T postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 -c) ++
        ["CREATE TABLE agents (uid text PRIMARY KEY); INSERT INTO agents VALUES #{values}"],
      env
    )
  end

  defp migration_env(project) do
    [
      {"ANKOLE_SECRET_BASE", "migration-test"},
      {"RELEASE_COOKIE", "migration-test"},
      {"POSTGRES_PASSWORD", "migration-test"},
      {"ANKOLE_HOST", "ankole.localhost"},
      {"ACME_EMAIL", "test@example.test"},
      {"ANKOLE_DOCKER_GID", "0"},
      {"ANKOLE_WORKER_INSTALLATION", project},
      {"COMPOSE_PROJECT_NAME", project}
    ]
  end

  defp docker_provider(project, image) do
    {:ok, settings} = Configuration.parse(Docker.definition().schema, "network: bridge\n")

    %Provider{
      provider_id: "docker",
      kind: "docker",
      settings: settings,
      runtime: %{
        installation: project,
        image: image,
        runtime_fabric_endpoint: "ws://127.0.0.1:1/runtime-fabric/worker",
        source_root: nil,
        internal_skills_root: nil
      }
    }
  end

  # Runs a shell script as root in the migration image with the volumes
  # mounted, and returns its output.
  defp in_volumes!(mounts, script) do
    mount_args =
      Enum.flat_map(mounts, fn {volume, target} ->
        ["--mount", "type=volume,source=#{volume},target=#{target}"]
      end)

    docker!(
      ["run", "--rm", "--network", "none"] ++
        mount_args ++ ["--entrypoint", "sh", "docker:29-cli", "-ec", script]
    )
  end

  defp run_migration(project, env) do
    docker!(
      [
        "compose",
        "-f",
        @compose,
        "-p",
        project,
        "up",
        "--no-deps",
        "--force-recreate",
        "--abort-on-container-exit",
        "--exit-code-from",
        "migrate-agent-homes",
        "migrate-agent-homes"
      ],
      env
    )
  end

  defp docker!(args, env \\ []) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true, env: env)
    assert status == 0, "docker #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end
end
