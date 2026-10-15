defmodule Ankole.FunctionComputeWorkerBootstrapIntegrationTest do
  @moduledoc """
  The real contract-file entry in Linux, started with the template commands as
  Function Compute runs them. This does not exercise Aliyun or envd.
  """
  use ExUnit.Case, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.AgentWorkers.FunctionCompute.Images
  @moduletag timeout: 300_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  test "the template waits for a contract, keeps the Worker as root, and consumes its contract once" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    name = "ankole-fc-native-#{System.unique_integer([:positive])}"
    helper = name <> "-delete"
    platform = name <> ":platform"
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)

    on_exit(fn ->
      for container <- [name, helper] do
        case System.cmd("docker", ["inspect", container], stderr_to_stdout: true) do
          {_, 0} ->
            docker!(["stop", "--time", "10", container])
            docker!(["rm", container])

          {_, 1} ->
            :ok
        end
      end

      docker!(["volume", "rm", name])
      System.cmd("docker", ["image", "rm", platform], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    build_platform_image!(dir, image, platform)
    docker!(["volume", "create", name])
    start(name, name, platform)
    await_ready!(name)
    await!(name, "test ! -f /run/ankole-worker.pid")

    contract = %{
      "WORKER_ID" => "fc-native-agent",
      "ANKOLE_WORKER_STORAGE" => "mounted",
      "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => "ws://127.0.0.1:1/runtime-fabric/worker",
      "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "native-contract-test"
    }

    deliver(name, dir, contract)

    await!(
      name,
      "test -f /run/ankole-worker.pid; test ! -f /run/ankole/awaiting-contract; test ! -f /run/ankole/contract.json"
    )

    pid = root!(name, ["cat", "/run/ankole-worker.pid"]) |> String.trim()

    user_check = ~S"""
    test "$(stat -c %a /run/ankole)" = 700
    ! command -v sudo
    for path in /proc/[0-9]*/cmdline; do
      command=$(tr '\0' ' ' < "$path" 2>/dev/null) || continue
      if [ "$command" = 'bun /repo/app/agent_computer/src/main.ts ' ]; then
        status=${path%cmdline}status
        test "$(awk '/^Uid:/{print $2}' "$status")" = 0
        test "$(awk '/^Gid:/{print $2}' "$status")" = 0
        exit 0
      fi
    done
    exit 1
    """

    await!(name, user_check)

    # sudo keeps only a few variables. The Worker still has every variable of
    # the image with the image's value.
    image_environment =
      docker!(["image", "inspect", "--format", "{{json .Config.Env}}", image])
      |> String.trim()
      |> Ankole.JSON.decode!()

    environment = worker_environment!(name)
    assert image_environment -- environment == []

    docker!([
      "exec",
      "--user",
      "1000:1000",
      name,
      "bash",
      "-ec",
      "! cat /proc/#{pid}/environ >/dev/null 2>&1"
    ])

    # The Worker gets the image variables and the contract, not those of sudo.
    assert Enum.filter(environment, &String.starts_with?(&1, ["SUDO_", "USER=", "LOGNAME="])) ==
             []

    docker!([
      "exec",
      "--user",
      "1000:1000",
      name,
      "bash",
      "-ec",
      "printf original > /workspace/proof; test \"$(readlink /agents/fc-native-agent)\" = /workspace"
    ])

    deliver(name, dir, contract)
    assert root!(name, ["cat", "/run/ankole-worker.pid"]) |> String.trim() == pid
    # The consumed template process cannot start another entry after a retry.
    root!(name, ["test", "-f", "/run/ankole/contract.json"])
    docker!(["stop", "--time", "10", name])
    start(helper, name, platform)
    await_ready!(helper)
    await!(helper, "test -f /workspace/proof")
    deletion = %{"WORKER_ID" => "fc-native-agent", "ANKOLE_WORKER_TASK" => "delete_storage"}
    deliver(helper, dir, deletion)

    await!(
      helper,
      "test -f /run/ankole/task-done; test ! -e /workspace/proof; test ! -f /run/ankole/contract.json"
    )

    # The contract reader has exited before the Agent UID is used again.
    await!(helper, ~S|test "$(tr '\0' ' ' < /proc/1/cmdline)" = 'sleep infinity '|)

    root!(helper, ["bash", "-ec", "printf reused > /workspace/proof"])
    deliver(helper, dir, deletion)
    assert root!(helper, ["cat", "/workspace/proof"]) == "reused"
    root!(helper, ["test", "-f", "/run/ankole/contract.json"])
  end

  test "the entry keeps writable Home ownership and rejects a read-only Home" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")

    args = [
      "run",
      "--rm",
      "--env",
      "WORKER_ID=fc-writable-agent",
      "--env",
      "ANKOLE_WORKER_STORAGE=mounted",
      "--entrypoint",
      "/usr/local/bin/ankole-worker-entry"
    ]

    docker!(
      args ++
        [
          "--tmpfs",
          "/workspace:uid=0,gid=0,mode=1777",
          image,
          "bash",
          "-ec",
          ~S|test "$(id -u)" = 0; test "$(stat -c %u /workspace)" = 0; setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs -- sh -ec 'printf writable > /workspace/proof; test "$(cat /workspace/proof)" = writable'|
        ]
    )

    {output, status} =
      System.cmd("docker", args ++ ["--tmpfs", "/workspace:ro,mode=1777", image, "true"],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "chown: changing ownership of '/workspace': Read-only file system"
  end

  # The Worker image has no sudo. A second-generation template keeps sudo and
  # gives the default user of the platform, uid 1000, sudo without a password
  # (WP 3.7). The Debian package keeps its default env_reset and secure_path.
  defp build_platform_image!(dir, image, tag) do
    File.write!(Path.join(dir, "Dockerfile"), """
    FROM #{image}
    RUN apt-get update \\
      && apt-get install -y --no-install-recommends sudo \\
      && rm -rf /var/lib/apt/lists/* \\
      && echo '#1000 ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/function-compute \\
      && chmod 0440 /etc/sudoers.d/function-compute
    """)

    docker!(["build", "--tag", tag, dir])
  end

  # The platform runs the start command in the background as its default user,
  # through a login shell as E2B envd does, and keeps the sandbox after the
  # command exits.
  defp start(name, volume, image) do
    docker!([
      "run",
      "-d",
      "--name",
      name,
      "--user",
      "1000:1000",
      "--mount",
      "type=volume,src=#{volume},dst=/workspace",
      "--entrypoint",
      "bash",
      image,
      "-lc",
      Images.start_command() <> " & wait; exec sleep infinity"
    ])
  end

  defp await_ready!(name) do
    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               {_, status} =
                 System.cmd(
                   "docker",
                   ["exec", "--user", "1000:1000", name, "bash", "-lc", Images.ready_command()],
                   stderr_to_stdout: true
                 )

               status == 0
             end)
  end

  defp worker_environment!(name) do
    script = ~S"""
    for path in /proc/[0-9]*/cmdline; do
      if [ "$(tr '\0' ' ' < "$path" 2>/dev/null)" = 'bun /repo/app/agent_computer/src/main.ts ' ]; then
        cat "${path%cmdline}environ" && exit 0
      fi
    done
    exit 1
    """

    # Without CAP_SYS_PTRACE, only the Worker's own uid can read its environ.
    assert {:ok, environment} =
             wait_until(deadline(15_000), fn ->
               case System.cmd("docker", [
                      "exec",
                      "--user",
                      "0:0",
                      name,
                      "bash",
                      "-ec",
                      script
                    ]) do
                 {environment, 0} -> {:ok, String.split(environment, <<0>>, trim: true)}
                 _ -> false
               end
             end)

    environment
  end

  defp deliver(name, dir, contract) do
    file = Path.join(dir, "contract.json")
    File.write!(file, Ankole.JSON.encode!(contract))
    docker!(["cp", file, "#{name}:/run/ankole/contract.json"])
  end

  defp await!(name, script) do
    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               {_, status} =
                 System.cmd("docker", ["exec", "--user", "0", name, "bash", "-ec", script],
                   stderr_to_stdout: true
                 )

               status == 0
             end)
  end

  # The container runs as uid 1000. The checks read root-only files, as envd can.
  defp root!(name, command), do: docker!(["exec", "--user", "0", name | command])

  defp docker!(args) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, "docker #{Enum.join(args, " ")}\n#{output}"
    output
  end
end
