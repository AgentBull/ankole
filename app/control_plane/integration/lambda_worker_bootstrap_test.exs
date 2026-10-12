defmodule Ankole.LambdaWorkerBootstrapIntegrationTest do
  @moduledoc "The real Lambda entry and NFS 4.1 path in Linux containers, without an AWS API substitute."
  use ExUnit.Case, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  @moduletag timeout: 240_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  test "hook redelivery cannot restart a writer or repeat a committed NFS deletion" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    server_image = System.fetch_env!("ANKOLE_NFS_TEST_SERVER_IMAGE")
    name = "ankole-lambda-native-#{System.unique_integer([:positive])}"
    server = name <> "-nfs"
    names = Enum.map(~w(first second peer cleanup), &(name <> "-" <> &1))
    [first, second, peer, cleanup] = names
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)
    replacement = name <> ":replacement"

    on_exit(fn ->
      Enum.each(names, &remove_container/1)
      System.cmd("docker", ["exec", server, "/usr/sbin/rpc.nfsd", "0"], stderr_to_stdout: true)
      remove_container(server)
      docker!(["volume", "rm", name])
      docker!(["network", "rm", name])
      System.cmd("docker", ["image", "rm", replacement], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    docker!(["network", "create", name])
    docker!(["volume", "create", name])

    docker!([
      "run",
      "-d",
      "--name",
      server,
      "--privileged",
      "--network",
      name,
      "--mount",
      "type=volume,src=#{name},dst=/export",
      server_image
    ])

    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               case System.cmd("docker", ["exec", server, "cat", "/proc/fs/nfsd/threads"],
                      stderr_to_stdout: true
                    ) do
                 {"4\n", 0} -> true
                 _ -> false
               end
             end)

    url = start(first, image, name, "worker")
    assert hook(url, "ready", %{}).status == 200
    docker!(["exec", first, "bash", "-ec", "test ! -e /run/ankole-worker.pid"])
    contract = contract("native-agent", server)
    assert hook(url, "run", contract).status == 200
    entry_pid = docker!(["exec", first, "cat", "/run/ankole-worker.pid"])
    assert hook(url, "run", contract).status == 200
    assert docker!(["exec", first, "cat", "/run/ankole-worker.pid"]) == entry_pid
    assert hook(url, "run", contract("peer-agent", server)).status == 409

    worker_identity!(first)
    mount = docker!(["exec", first, "findmnt", "-no", "FSTYPE,OPTIONS", "/workspace"])
    assert mount =~ "nfs4"
    assert mount =~ "vers=4.1"
    assert mount =~ "hard"

    docker!([
      "exec",
      "--user",
      "1000:1000",
      first,
      "bash",
      "-ec",
      "printf persistent > /workspace/proof; sync /workspace/proof; test \"$(readlink /agents/native-agent)\" = /workspace; test ! -e /workspace/peer-agent"
    ])

    server_ip =
      docker!([
        "inspect",
        "--format",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        server
      ])
      |> String.trim()

    denied = ~S"""
    import errno, socket, sys
    sock = socket.socket()
    try:
        sock.connect((sys.argv[1], 2049))
    except OSError as error:
        assert error.errno == errno.EACCES, error
    else:
        raise AssertionError('uid 1000 reached the shared NFS server')
    """

    docker!(["exec", "--user", "1000:1000", first, "python3", "-c", denied, server_ip])
    peer_url = start(peer, image, name, "worker")
    assert hook(peer_url, "run", contract("peer-agent", server)).status == 200

    docker!([
      "exec",
      "--user",
      "1000:1000",
      peer,
      "bash",
      "-ec",
      "printf peer > /workspace/proof; sync /workspace/proof; test ! -e /workspace/native-agent"
    ])

    assert hook(url, "terminate", %{}).status == 200
    remove_container(first)

    File.write!(
      Path.join(dir, "Dockerfile"),
      "FROM #{image}\nRUN printf replacement > /etc/ankole-lambda-revision\n"
    )

    docker!(["build", "-t", replacement, dir])
    second_url = start(second, replacement, name, "worker")
    assert hook(second_url, "run", contract).status == 200

    assert docker!(["exec", "--user", "1000:1000", second, "cat", "/workspace/proof"]) ==
             "persistent"

    assert docker!(["exec", second, "cat", "/etc/ankole-lambda-revision"]) == "replacement"
    assert hook(second_url, "terminate", %{}).status == 200
    remove_container(second)

    cleanup_url = start(cleanup, image, name, "delete_storage")

    deletion = %{
      "microvmId" => "local-helper",
      "runHookPayload" =>
        Ankole.JSON.encode!(%{
          "WORKER_ID" => "native-agent",
          "ANKOLE_WORKER_STORAGE" => "nfs",
          "ANKOLE_WORKER_NFS_SOURCE" => server <> ":/agents"
        })
    }

    assert hook(cleanup_url, "run", deletion).status == 200

    docker!([
      "exec",
      server,
      "bash",
      "-ec",
      "test ! -e /export/agents/native-agent; test -z \"$(ls -A /export/agents/.deleted)\""
    ])

    # The short-lived entry has ended, but the hooks remain available until
    # the control plane terminates the ready helper.
    assert hook(cleanup_url, "ready", %{}).status == 200
    assert docker!(["inspect", "--format", "{{.State.Running}}", cleanup]) == "true\n"
    assert docker!(["exec", "--user", "1000:1000", peer, "cat", "/workspace/proof"]) == "peer"

    # A repeated hook must not run removal again, even if a new directory
    # appears at the old path.
    docker!([
      "exec",
      server,
      "bash",
      "-ec",
      "mkdir /export/agents/native-agent; printf new > /export/agents/native-agent/proof"
    ])

    assert hook(cleanup_url, "run", deletion).status == 200
    assert docker!(["exec", server, "cat", "/export/agents/native-agent/proof"]) == "new"
  end

  defp start(name, image, network, task) do
    docker!([
      "run",
      "-d",
      "--name",
      name,
      "--privileged",
      "--network",
      network,
      "--publish",
      "127.0.0.1::8080",
      "--env",
      "ANKOLE_WORKER_BOOTSTRAP=lambda",
      "--env",
      "ANKOLE_WORKER_TASK=#{task}",
      image
    ])

    address = docker!(["port", name, "8080/tcp"]) |> String.trim()
    url = "http://" <> address

    assert {:ok, true} =
             wait_until(deadline(10_000), fn ->
               case Req.post(url <> "/aws/lambda-microvms/runtime/v1/ready",
                      json: %{},
                      retry: false
                    ) do
                 {:ok, %{status: 200}} -> true
                 _ -> false
               end
             end)

    url
  end

  defp contract(uid, server),
    do: %{
      "microvmId" => "local-#{uid}",
      "runHookPayload" =>
        Ankole.JSON.encode!(%{
          "WORKER_ID" => uid,
          "ANKOLE_WORKER_STORAGE" => "nfs",
          "ANKOLE_WORKER_NFS_SOURCE" => server <> ":/agents",
          "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => "ws://127.0.0.1:1/runtime-fabric/worker",
          "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "native-bootstrap-test"
        })
    }

  defp hook(url, name, body),
    do:
      Req.post!(url <> "/aws/lambda-microvms/runtime/v1/" <> name,
        json: body,
        retry: false,
        receive_timeout: 60_000
      )

  defp worker_identity!(container) do
    script = ~S"""
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

    assert {:ok, true} =
             wait_until(deadline(10_000), fn ->
               {_, status} =
                 System.cmd("docker", ["exec", container, "bash", "-ec", script],
                   stderr_to_stdout: true
                 )

               status == 0
             end)

    docker!(["exec", container, "bash", "-ec", "! command -v sudo"])
  end

  defp remove_container(name) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} ->
        docker!(["stop", "--time", "60", name])
        docker!(["rm", name])

      {_, 0} ->
        docker!(["rm", name])

      {_missing, 1} ->
        :ok
    end
  end

  defp docker!(args) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, "docker #{Enum.join(args, " ")}\n#{output}"
    output
  end
end
