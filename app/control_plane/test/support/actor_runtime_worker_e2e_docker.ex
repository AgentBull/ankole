defmodule Ankole.ActorRuntimeWorkerE2E.DockerWorker do
  @moduledoc """
  Docker process helpers for the real Agent Computer worker e2e tests.

  The e2e test module owns RuntimeFabric, database assertions, and signal input
  setup. This module owns only the container process boundary so the test body
  stays focused on worker behavior instead of Docker argument assembly.
  """

  import ExUnit.Assertions

  @docker_image "ankole-agent-computer:0.1.0"

  @doc "Starts a long-running Agent Computer Docker worker process for e2e tests."
  def start_docker_worker!(opts) do
    name = "ankole-worker-e2e-#{System.unique_integer([:positive])}"
    worker_id = Keyword.fetch!(opts, :worker_id)

    runtime_fabric_url =
      runtime_fabric_url!(
        Keyword.fetch!(opts, :endpoint),
        Keyword.fetch!(opts, :worker_auth_key)
      )

    args =
      [
        "run",
        "--rm",
        "--name",
        name
      ] ++
        docker_agent_computer_runtime_args() ++
        docker_dev_agent_computer_mount_args() ++
        docker_dev_workspace_mount_args() ++
        docker_env_args(
          [
            {"WORKER_ID", worker_id},
            {"RUNTIME_FABRIC_URL", runtime_fabric_url}
          ] ++ docker_worker_passthrough_env()
        ) ++ [@docker_image]

    port =
      Port.open({:spawn_executable, docker_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    %{kind: :docker, name: name, port: port, output: []}
  end

  @doc "Runs the worker image once with custom env and returns command output."
  def docker_run_worker_once(env) do
    args =
      [
        "run",
        "--rm"
      ] ++
        docker_agent_computer_runtime_args() ++
        docker_dev_agent_computer_mount_args() ++
        docker_dev_workspace_mount_args() ++
        docker_env_args(env) ++ [@docker_image]

    System.cmd(docker_path(), args, stderr_to_stdout: true)
  end

  @doc "Force-removes a Docker worker container and closes the watched port."
  def cleanup_docker_worker(%{name: name, port: port}) do
    System.cmd(docker_path(), ["rm", "-f", name], stderr_to_stdout: true)
    close_port(port)
  end

  @doc "Converts the host-bound RuntimeFabric endpoint into a container URL."
  def docker_host_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "tcp", port: port} when is_integer(port) ->
        "tcp://host.docker.internal:#{port}"

      _uri ->
        flunk("unexpected router endpoint for Docker worker: #{endpoint}")
    end
  end

  @doc "Asserts the e2e Docker image exists before starting worker tests."
  def assert_docker_image! do
    case System.cmd(docker_path(), ["image", "inspect", @docker_image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("missing Docker image #{@docker_image}, status=#{status}, output=#{output}")
    end
  end

  defp runtime_fabric_url!("tcp://" <> rest, worker_auth_key) do
    "tcp://:#{URI.encode_www_form(worker_auth_key)}@#{rest}"
  end

  defp docker_env_args(env) do
    Enum.flat_map(env, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  # Agent Computer is a Linux-container runtime. The command tool always enters
  # bubblewrap; Docker must grant the kernel surface needed for strong bwrap
  # instead of falling back to host execution. If these flags are unavailable, the
  # worker startup probe may downgrade to weak bwrap and logs that explicitly.
  defp docker_agent_computer_runtime_args do
    [
      "--cap-add",
      "SYS_ADMIN",
      "--security-opt",
      "seccomp=unconfined",
      "--security-opt",
      "systempaths=unconfined",
      "--add-host",
      "host.docker.internal=host-gateway"
    ]
  end

  defp docker_worker_passthrough_env do
    [
      "ANKOLE_LLM_TURN_TIMEOUT_MS",
      "ANKOLE_LLM_COMPRESSION_TIMEOUT_MS",
      "ANKOLE_LLM_AMBIENT_RECOGNIZER_TIMEOUT_MS"
    ]
    |> Enum.flat_map(fn key ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> [{key, value}]
        _value -> []
      end
    end)
  end

  # Development-only fast path for the real worker e2e. The worker process,
  # Linux userspace packages, native binaries, node_modules, and tool sandboxing
  # still come from the Agent Computer container; this mount only replaces the
  # container's TS source tree to shorten edit/run feedback.
  defp docker_dev_agent_computer_mount_args do
    case System.get_env("ANKOLE_E2E_MOUNT_AGENT_COMPUTER_SRC") do
      "1" ->
        src = Path.join([repo_root(), "app", "agent_computer", "src"])
        ["-v", "#{src}:/repo/app/agent_computer/src:ro"]

      _value ->
        []
    end
  end

  # E2E artifact mount. The worker, commands, and bubblewrap sandbox still run
  # in the Linux container; this only makes /workspace contents inspectable from
  # the host after a failed real-provider run.
  defp docker_dev_workspace_mount_args do
    case System.get_env("ANKOLE_E2E_HOST_WORKSPACE_ROOT") do
      nil ->
        []

      "" ->
        []

      host_root ->
        File.mkdir_p!(host_root)
        File.mkdir_p!(Path.join(host_root, "shared/user-files"))
        File.mkdir_p!(Path.join(host_root, "shared/skills/agents"))
        File.mkdir_p!(Path.join(host_root, ".sessions"))
        ["-v", "#{Path.expand(host_root)}:/workspace"]
    end
  end

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  end

  defp close_port(_port), do: :ok

  defp repo_root, do: Path.expand("../../../..", __DIR__)

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end
end
