defmodule Ankole.E2E.DockerWorker do
  @moduledoc """
  Docker process adapter for the real Agent Computer worker e2e tests.

  `Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap` owns worker auth, security, connectivity,
  and Agent Home guarantees. This adapter adds only test container lifecycle,
  optional mounted source, and the development command override.
  """

  import ExUnit.Assertions

  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.Docker

  @doc "Starts a long-running Agent Computer Docker worker process for e2e tests."
  def start_docker_worker!(opts) do
    name = unique_worker_name()
    image = docker_image()
    {agents_root, persist_agents?} = agents_root(name)

    {:ok, spec} =
      WorkerBootstrap.worker_spec(
        endpoint: Keyword.fetch!(opts, :endpoint),
        worker_id: Keyword.fetch!(opts, :worker_id),
        auth_key: Keyword.fetch!(opts, :worker_auth_key),
        image: image,
        agents_root: agents_root
      )

    Enum.each(spec.host_setup_dirs, &File.mkdir_p!/1)

    args =
      Docker.argv(spec,
        name: name,
        additional_mounts: docker_dev_agent_computer_mounts(),
        command: docker_dev_agent_computer_command()
      )

    port =
      Port.open({:spawn_executable, docker_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    %{
      kind: :docker,
      name: name,
      port: port,
      output: [],
      agents_root: agents_root,
      persist_agents?: persist_agents?
    }
  end

  @doc "Runs the worker image once with custom env and returns command output."
  def docker_run_worker_once(env) do
    {:ok, spec} = WorkerBootstrap.container_spec(image: docker_image())

    args =
      Docker.argv(spec,
        additional_env: Map.new(env),
        additional_mounts: docker_dev_agent_computer_mounts(),
        command: docker_dev_agent_computer_command()
      )

    System.cmd(docker_path(), args, stderr_to_stdout: true)
  end

  @doc "Force-removes a Docker worker container, its temporary Agent root, and its watched port."
  def cleanup_docker_worker(%{
        name: name,
        port: port,
        agents_root: agents_root,
        persist_agents?: persist_agents?
      }) do
    System.cmd(docker_path(), ["rm", "-f", name], stderr_to_stdout: true)
    close_port(port)

    unless persist_agents? do
      File.rm_rf(agents_root)
    end

    :ok
  end

  @doc "Hard-kills a running worker container mid-turn (chaos scenarios)."
  def kill_docker_worker!(%{name: name, port: port}) do
    {_output, 0} = System.cmd(docker_path(), ["kill", name], stderr_to_stdout: true)
    close_port(port)
    :ok
  end

  @doc "Sends one process signal to a running worker container without closing its watched port."
  def signal_docker_worker!(%{name: name}, signal) when is_binary(signal) do
    {_output, 0} =
      System.cmd(docker_path(), ["kill", "--signal", signal, name], stderr_to_stdout: true)

    :ok
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
    image = docker_image()

    case System.cmd(docker_path(), ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("missing Docker image #{image}, status=#{status}, output=#{output}")
    end
  end

  @doc "Asserts a running e2e worker received the canonical bootstrap contract."
  def assert_launch_contract!(%{name: name, agents_root: agents_root}) do
    {output, 0} = System.cmd(docker_path(), ["inspect", name], stderr_to_stdout: true)
    [inspection] = Ankole.JSON.decode!(output)

    host_config = inspection["HostConfig"]
    env = inspection["Config"]["Env"]
    mounts = Map.new(inspection["Mounts"], &{&1["Destination"], &1})

    assert "CAP_SYS_ADMIN" in host_config["CapAdd"]
    assert "seccomp=unconfined" in host_config["SecurityOpt"]
    assert host_config["MaskedPaths"] == []
    assert host_config["ReadonlyPaths"] == []

    assert "host.docker.internal:host-gateway" in host_config["ExtraHosts"]

    assert Enum.any?(env, &String.starts_with?(&1, "WORKER_ID="))
    assert Enum.any?(env, &String.starts_with?(&1, "ANKOLE_RUNTIME_FABRIC_ENDPOINT="))
    assert Enum.any?(env, &String.starts_with?(&1, "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY="))
    assert Enum.any?(env, &(&1 == "ANKOLE_AGENTS_ROOT=/agents"))
    assert mounts["/agents"]["Source"] == agents_root
    assert mounts["/agents"]["RW"]

    :ok
  end

  defp docker_dev_agent_computer_command do
    case mount_agent_computer_src?() do
      true -> ["/bin/sh", "-lc", "cd /repo/app/agent_computer && exec bun src/main.ts"]
      false -> []
    end
  end

  defp docker_dev_agent_computer_mounts do
    case mount_agent_computer_src?() do
      true ->
        [
          %{
            source: Path.join([repo_root(), "app", "agent_computer", "src"]),
            target: "/repo/app/agent_computer/src",
            readonly: true
          }
        ]

      false ->
        []
    end
  end

  defp mount_agent_computer_src?,
    do: System.get_env("ANKOLE_E2E_MOUNT_AGENT_COMPUTER_SRC") == "1"

  defp agents_root(name) do
    case System.get_env("ANKOLE_E2E_HOST_AGENTS_ROOT") do
      value when is_binary(value) and value != "" ->
        {Path.join(Path.expand(value), name), true}

      _value ->
        {Path.join(System.tmp_dir!(), name), false}
    end
  end

  defp unique_worker_name do
    suffix = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
    "ankole-worker-e2e-#{suffix}"
  end

  defp docker_image, do: System.fetch_env!("ANKOLE_E2E_WORKER_IMAGE")

  defp close_port(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_port), do: :ok

  defp repo_root, do: Path.expand("../../..", __DIR__)

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end
end
