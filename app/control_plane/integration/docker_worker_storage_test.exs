defmodule Ankole.DockerWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Docker, ProviderKind}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{Configuration, Provider}
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @moduletag timeout: 180_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  test "a command-started entry cleans detached writers before restart and exit" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    name = "ankole-supervisor-command-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Stop the test container before removal. It has no persistent data.
      System.cmd("docker", ["kill", name], stderr_to_stdout: true)
      System.cmd("docker", ["wait", name], stderr_to_stdout: true)
      System.cmd("docker", ["rm", name], stderr_to_stdout: true)
    end)

    script = ~S"""
    cat > /tmp/test-worker.sh <<'WORKER'
    set -eu
    test "$EUID" -eq 1000
    test "$PPID" -ne 1
    if [ -e /workspace/previous-writer ]; then
      pid=$(cat /workspace/previous-writer)
      test ! -e "/proc/$pid"
      before=$(wc -l < /workspace/writes)
      sleep 0.2
      test "$(wc -l < /workspace/writes)" -eq "$before"
      setsid bash -c 'while :; do echo write >> /workspace/drain-writes; sleep 0.01; done' &
      echo $! > /workspace/drain-writer
      while [ ! -s /workspace/drain-writes ]; do sleep 0.01; done
      exit 0
    fi
    setsid bash -c 'while :; do echo write >> /workspace/writes; sleep 0.01; done' &
    echo $! > /workspace/previous-writer
    while [ ! -s /workspace/writes ]; do sleep 0.01; done
    exit 7
    WORKER
    /usr/local/bin/ankole-worker-command-entry bash /tmp/test-worker.sh &
    entry=$!
    wait "$entry"
    test ! -e "/proc/$(cat /workspace/previous-writer)"
    test ! -e "/proc/$(cat /workspace/drain-writer)"
    before=$(wc -l < /workspace/drain-writes)
    sleep 0.2
    test "$(wc -l < /workspace/drain-writes)" -eq "$before"
    /usr/local/bin/ankole-worker-command-entry bash -ec 'touch /workspace/second-worker; exit 99'
    test ! -e /workspace/second-worker
    echo writer-cleanup-passed
    """

    output =
      docker!([
        "run",
        "--name",
        name,
        "--env",
        "WORKER_ID=supervisor-command-test",
        "--env",
        "ANKOLE_WORKER_STORAGE=mounted",
        "--entrypoint",
        "bash",
        image,
        "-ec",
        script
      ])

    assert output =~ "worker.restart_scheduled"
    assert output =~ "writer-cleanup-passed"
  end

  test "a delayed command cannot start a second Worker after the supervisor crashes" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    name = "ankole-supervisor-late-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      System.cmd("docker", ["kill", name], stderr_to_stdout: true)
      System.cmd("docker", ["wait", name], stderr_to_stdout: true)
      System.cmd("docker", ["rm", name], stderr_to_stdout: true)
    end)

    script = ~S"""
    /usr/local/bin/ankole-worker-command-entry bash -ec '
      setsid bash -c "while :; do echo write >> /workspace/writes; sleep 0.01; done" &
      echo $! > /workspace/writer
      sleep 600
    ' &
    entry=$!
    while [ ! -s /workspace/writes ]; do sleep 0.01; done
    tini=$(cat /run/ankole-worker.pid)
    supervisor=$(cat "/proc/$tini/task/$tini/children")
    kill -KILL $supervisor
    wait "$entry" || true
    before=$(wc -l < /workspace/writes)
    sleep 0.2
    test "$(wc -l < /workspace/writes)" -gt "$before"
    # Old processes can outlive a killed supervisor. Even if the lock is
    # available again, the root-owned PID file must prevent a second entry.
    /usr/local/bin/ankole-worker-command-entry bash -ec 'touch /workspace/second-worker; exit 99'
    test ! -e /workspace/second-worker
    echo delayed-command-refused
    """

    output =
      docker!([
        "run",
        "--name",
        name,
        "--env",
        "WORKER_ID=supervisor-late-test",
        "--env",
        "ANKOLE_WORKER_STORAGE=mounted",
        "--entrypoint",
        "bash",
        image,
        "-ec",
        script
      ])

    assert output =~ "delayed-command-refused"
  end

  test "Home survives container deletion and an image change; rebuild drops only cache; storage deletion drops both volumes" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    socket = System.get_env("ANKOLE_WORKER_PROVIDER_TEST_SOCKET", "/var/run/docker.sock")
    uid = "storage-#{System.unique_integer([:positive])}"
    installation = "wp-#{System.unique_integer([:positive])}"

    {:ok, settings} =
      Configuration.parse(Docker.definition().schema, Ankole.JSON.encode!(%{socket: socket}))

    provider = %Provider{
      provider_id: "docker-test",
      kind: "docker",
      settings: settings,
      runtime: %{
        installation: installation,
        image: image,
        runtime_fabric_endpoint: "ws://127.0.0.1:1/runtime-fabric/worker",
        source_root: nil,
        internal_skills_root: nil
      }
    }

    home = ProviderKind.storage_name(installation, uid)
    cache = home <> "-cache"
    next_image = "ankole-worker-provider-test:#{installation}"
    build_dir = Path.join(System.tmp_dir!(), installation)

    on_exit(fn ->
      remove_instances(provider, uid)
      assert {:ok, nil} = Docker.delete_storage(provider, uid, nil)
      System.cmd("docker", ["image", "rm", next_image], stderr_to_stdout: true)
      File.rm_rf!(build_dir)
    end)

    assert :ok = Docker.check(provider)
    assert :ok = Docker.prepare_image(provider, image)
    assert :ok = Docker.prepare_storage(provider, uid)
    assert :ok = Docker.prepare_storage(provider, uid)
    first = start_instance(provider, uid, "generation-one")

    assert exec(
             first,
             "test \"$(id -u)\" = 1000; test \"$(readlink /agents/$WORKER_ID)\" = /workspace; test \"$(awk '/^Uid:/{print $2}' /proc/1/status)\" = 1000; ! command -v sudo; printf persistent > /workspace/keep; printf cache > /var/cache/ankole/keep; printf legacy > /agents/$WORKER_ID/old-path"
           ) == ""

    assert {:ok, []} = Docker.list_instances(%{provider | provider_id: "another-provider"}, :all)

    remove_instances(provider, uid)
    assert volume_exists?(home)
    assert volume_exists?(cache)

    File.mkdir_p!(build_dir)

    File.write!(
      Path.join(build_dir, "Dockerfile"),
      "FROM #{image}\nRUN printf upgraded > /etc/worker-provider-test-version\n"
    )

    docker!(["build", "--pull=false", "-t", next_image, build_dir])

    refute docker!(["image", "inspect", "--format", "{{.Id}}", image]) ==
             docker!(["image", "inspect", "--format", "{{.Id}}", next_image])

    provider = put_in(provider.runtime.image, next_image)
    second = start_instance(provider, uid, "generation-two")

    assert exec(
             second,
             "cat /workspace/keep /var/cache/ankole/keep /agents/$WORKER_ID/old-path /etc/worker-provider-test-version"
           ) == "persistentcachelegacyupgraded"

    remove_instances(provider, uid)
    assert :ok = Docker.delete_cache(provider, uid)
    assert volume_exists?(home)
    refute volume_exists?(cache)
    assert :ok = Docker.prepare_storage(provider, uid)
    third = start_instance(provider, uid, "generation-three")

    assert exec(
             third,
             "test ! -e /var/cache/ankole/keep; cat /workspace/keep /workspace/old-path"
           ) == "persistentlegacy"

    remove_instances(provider, uid)
    assert {:ok, nil} = Docker.delete_storage(provider, uid, nil)
    refute volume_exists?(home)
    refute volume_exists?(cache)
  end

  defp start_instance(provider, uid, generation) do
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, generation, "local-storage-test")
    assert {:ok, nil} = Docker.create_instance(provider, spec)
    name = ProviderKind.instance_name(provider.runtime.installation, uid, generation)
    first_id = docker!(["inspect", "--format", "{{.Id}}", name])
    assert {:ok, nil} = Docker.create_instance(provider, spec)
    assert docker!(["inspect", "--format", "{{.Id}}", name]) == first_id

    assert {:ok, true} =
             wait_until(deadline(20_000), fn ->
               {_output, status} =
                 System.cmd(
                   "docker",
                   ["exec", "--user", "1000:1000", name, "test", "-L", "/agents/#{uid}"],
                   stderr_to_stdout: true
                 )

               status == 0
             end)

    name
  end

  defp remove_instances(provider, uid) do
    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               assert {:ok, instances} = Docker.list_instances(provider, uid)

               for instance <- instances,
                   do: assert(:ok = Docker.delete_instance(provider, instance, :now))

               instances == []
             end)
  end

  defp exec(name, script),
    do: docker!(["exec", "--user", "1000:1000", name, "bash", "-ec", script])

  defp volume_exists?(name) do
    {_output, status} = System.cmd("docker", ["volume", "inspect", name], stderr_to_stdout: true)
    status == 0
  end

  defp docker!(args) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, "docker #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end
end
