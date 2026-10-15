defmodule Ankole.E2E.DockerWorker do
  @moduledoc """
  Docker side of the Agent Computer e2e tests.

  The control plane under test creates each Agent's Worker container through
  its Docker provider, as a deployment does. This module configures that provider
  for one test with a unique installation label, gives the scenarios a handle
  for an Agent's current container, disturbs containers for chaos scenarios,
  and removes every container of the installation when the test exits.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ankole.Repo
  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Docker
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.AgentWorkers.AgentWorker

  @doc """
  Makes the control plane create Workers with the Docker provider for this
  test, connecting them to `endpoint`. Returns the installation label.
  """
  def install_provider!(endpoint) do
    installation = "e2e" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))
    {:ok, previous} = Config.fetch()
    :ok = put_runtime(installation, endpoint, docker_image())
    provider_id = provider_id!()
    {:ok, provider} = Providers.load(provider_id)

    on_exit(fn ->
      remove_provider_resources(provider)
      :ok = Config.put(Map.to_list(previous))
    end)

    installation
  end

  @doc """
  Makes the control plane of this test target another Worker image, as an
  upgraded control plane does. The lifecycle rules then replace the Workers
  of the old image.
  """
  def switch_image!(image) do
    {:ok, config} = Config.fetch()
    :ok = Config.put(Keyword.put(Map.to_list(config), :image, image))
  end

  @doc """
  Tags the test Worker image with a new local name and returns that name. The
  tag is removed when the test exits.
  """
  def tag_image!(label) do
    image =
      "ankole-e2e-#{label}:" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))

    {_output, 0} =
      System.cmd(docker_path(), ["tag", docker_image(), image], stderr_to_stdout: true)

    on_exit(fn -> System.cmd(docker_path(), ["rmi", image], stderr_to_stdout: true) end)
    image
  end

  @doc """
  Creates a container with Worker labels that the control plane did not
  create, and returns its name. The container is removed when the test exits.
  """
  def create_labeled_container!(installation, agent_uid, generation, provider_id \\ "e2e") do
    name = ProviderKind.instance_name(installation, agent_uid, generation)

    {_output, 0} =
      System.cmd(
        docker_path(),
        [
          "create",
          "--name",
          name,
          "--label",
          "ankole.worker=1",
          "--label",
          "ankole.installation=#{installation}",
          "--label",
          "ankole.provider=#{provider_id}",
          "--label",
          "ankole.agent-uid=#{agent_uid}",
          "--label",
          "ankole.generation=#{generation}",
          "--entrypoint",
          "true",
          docker_image()
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> remove_container(name) end)
    name
  end

  @doc """
  The image reference and the state (`running`, `exited`, ...) of a container,
  or `nil` when the container does not exist.
  """
  def container_info(name) when is_binary(name) do
    case System.cmd(
           docker_path(),
           ["inspect", "--format", "{{.Config.Image}} {{.State.Status}}", name],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        [image, status] = output |> String.trim() |> String.split(" ", parts: 2)
        %{image: image, status: status}

      {output, 1} ->
        assert String.downcase(output) =~ "no such object", output
        nil

      {output, status} ->
        flunk("Docker inspect failed (#{status}): #{output}")
    end
  end

  @doc "Creates the test provider before Agent assignment through the production domain."
  def provider_id! do
    case Providers.fetch("e2e") do
      {:ok, provider} ->
        provider.provider_id

      {:error, :worker_provider_not_found} ->
        assert {:ok, provider} =
                 Providers.create(%{
                   provider_id: "e2e",
                   display_name: "E2E Docker",
                   kind: "docker",
                   config: Ankole.JSON.encode!(%{socket: docker_socket(), network: "bridge"}),
                   credentials: %{}
                 })

        provider.provider_id
    end
  end

  defp put_runtime(installation, endpoint, image) do
    Config.put(
      image: image,
      runtime_fabric_endpoint: endpoint,
      installation: installation,
      internal_skills_root: internal_skills_root()
    )
  end

  defp internal_skills_root do
    case System.get_env("ANKOLE_INTERNAL_SKILLS_ROOT") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _unset -> nil
    end
  end

  @doc """
  The handle of an Agent's Worker container. The container name follows the
  row's generation, so a rebuilt Worker gets a new name; the helpers below
  read it again on every call.
  """
  def container(agent_uid), do: %{kind: :docker, agent_uid: agent_uid}

  @doc "The current container name of an Agent's Worker."
  def container_name(agent_uid) do
    {:ok, config} = Config.fetch()

    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{generation: generation} when is_binary(generation) ->
        ProviderKind.instance_name(config.installation, agent_uid, generation)

      other ->
        flunk("Agent #{agent_uid} has no Worker generation: #{inspect(other)}")
    end
  end

  @doc "Hard-kills an Agent's running Worker container (chaos scenarios)."
  def kill_docker_worker!(%{agent_uid: agent_uid}) do
    {_output, 0} =
      System.cmd(docker_path(), ["kill", container_name(agent_uid)], stderr_to_stdout: true)

    :ok
  end

  @doc "Sends one signal to the main process of an Agent's Worker container."
  def signal_docker_worker!(%{agent_uid: agent_uid}, signal) when is_binary(signal) do
    {_output, 0} =
      System.cmd(docker_path(), ["kill", "--signal", signal, container_name(agent_uid)],
        stderr_to_stdout: true
      )

    :ok
  end

  @doc """
  The exit codes of an Agent's Worker container since `since` (a
  `DateTime`), oldest first. Docker records them in its event log, so an exit
  stays visible after the control plane replaces the container.
  """
  def exit_codes_since(%{agent_uid: agent_uid}, %DateTime{} = since) do
    {output, 0} =
      System.cmd(
        docker_path(),
        [
          "events",
          "--since",
          Integer.to_string(DateTime.to_unix(since)),
          "--until",
          Integer.to_string(System.os_time(:second)),
          "--filter",
          "label=ankole.agent-uid=#{agent_uid}",
          "--filter",
          "label=ankole.provider=e2e",
          "--filter",
          "event=die",
          "--format",
          ~s({{index .Actor.Attributes "exitCode"}})
        ],
        stderr_to_stdout: true
      )

    output |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
  end

  @doc "Runs a command in an Agent's Worker container and returns its output."
  def exec!(%{agent_uid: agent_uid}, argv) when is_list(argv) do
    {output, status} =
      System.cmd(docker_path(), ["exec", "--user", "1000:1000", container_name(agent_uid) | argv],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end

  @doc """
  The last lines of a container log: the Worker of an Agent, or a container
  name.
  """
  def logs(%{agent_uid: agent_uid}) do
    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{generation: generation} when is_binary(generation) ->
        logs(container_name(agent_uid))

      _row ->
        ""
    end
  end

  def logs(name) when is_binary(name) do
    {output, _status} =
      System.cmd(docker_path(), ["logs", "--tail", "200", name], stderr_to_stdout: true)

    output
  end

  @doc """
  Starts a Worker container outside the control plane with custom env, for
  credential checks. The container is removed when the test exits.
  """
  def start_unmanaged_worker!(env, opts \\ []) do
    name =
      "ankole-e2e-unmanaged-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    env = [{"ANKOLE_WORKER_STORAGE", "mounted"} | env]

    mounts =
      case Keyword.get(opts, :home_volume) do
        nil -> []
        name -> ["--mount", "type=volume,source=#{name},target=/workspace"]
      end

    args =
      ["run", "--detach", "--name", name, "--add-host", "host.docker.internal:host-gateway"] ++
        env_args(env) ++ mounts ++ [docker_image()]

    {_output, 0} = System.cmd(docker_path(), args, stderr_to_stdout: true)
    on_exit(fn -> remove_container(name) end)
    name
  end

  @doc """
  Runs the Worker process of the image once with custom env and returns the
  output. It starts the process directly: the supervisor of the image would
  restart a process that fails.
  """
  def docker_run_worker_once(env) do
    args =
      ["run", "--rm", "--entrypoint", "bun"] ++
        env_args(env) ++ [docker_image(), "src/main.ts"]

    System.cmd(docker_path(), args, stderr_to_stdout: true)
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

  @doc """
  Asserts that the control plane created an Agent's container with the launch
  contract: the contract variables, the identity labels, no restart policy,
  no extra kernel capability, independent Home and cache, and read-only development source.
  """
  def assert_launch_contract!(agent_uid) do
    {output, 0} =
      System.cmd(docker_path(), ["inspect", container_name(agent_uid)], stderr_to_stdout: true)

    [inspection] = Ankole.JSON.decode!(output)
    host_config = inspection["HostConfig"]
    env = inspection["Config"]["Env"]
    labels = inspection["Config"]["Labels"]

    assert "WORKER_ID=#{agent_uid}" in env
    assert Enum.any?(env, &String.starts_with?(&1, "ANKOLE_RUNTIME_FABRIC_ENDPOINT="))
    assert Enum.any?(env, &String.starts_with?(&1, "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY="))
    assert "ANKOLE_WORKER_STORAGE=mounted" in env
    assert "CODEX_HOME=/workspace/.codex" in env
    assert "CODEX_SQLITE_HOME=/var/cache/ankole/codex" in env
    assert labels["ankole.agent-uid"] == agent_uid
    assert labels["ankole.worker"] == "1"
    assert labels["ankole.provider"] == Repo.get!(AgentWorker, agent_uid).provider_id
    assert host_config["RestartPolicy"]["Name"] == "no"
    refute "CAP_SYS_ADMIN" in (host_config["CapAdd"] || [])
    assert "host.docker.internal:host-gateway" in host_config["ExtraHosts"]

    targets = Enum.map(inspection["Mounts"] || [], & &1["Destination"])
    assert "/workspace" in targets
    assert "/var/cache/ankole" in targets

    allowed_targets = ["/workspace", "/var/cache/ankole", "/repo/app/agent_computer/src"]

    allowed_targets =
      if internal_skills_root(),
        do: ["/repo/internals/skills" | allowed_targets],
        else: allowed_targets

    assert targets -- allowed_targets == []
    mounts = Map.new(inspection["Mounts"], &{&1["Destination"], &1})
    assert mounts["/workspace"]["Type"] == "volume"
    assert mounts["/var/cache/ankole"]["Type"] == "volume"
    refute mounts["/workspace"]["Name"] == mounts["/var/cache/ankole"]["Name"]

    if root = internal_skills_root() do
      assert mounts["/repo/internals/skills"]["Type"] == "bind"

      source = mounts["/repo/internals/skills"]["Source"]
      # Docker Desktop reports the host path through its Linux VM mount.
      assert source == root or
               (:os.type() == {:unix, :darwin} and source == "/host_mnt" <> root)

      assert mounts["/repo/internals/skills"]["RW"] == false
      assert "ANKOLE_INTERNAL_SKILLS_ROOT=/repo/internals/skills" in env
    end

    assert exec!(container(agent_uid), [
             "sh",
             "-ec",
             "test \"$(id -u)\" = 1000; ! command -v sudo; test \"$(readlink /agents/$WORKER_ID)\" = /workspace"
           ]) == ""

    :ok
  end

  def storage_volumes(agent_uid) do
    {output, 0} =
      System.cmd(docker_path(), ["inspect", container_name(agent_uid)], stderr_to_stdout: true)

    [inspection] = Ankole.JSON.decode!(output)
    mounts = Map.new(inspection["Mounts"], &{&1["Destination"], &1["Name"]})
    %{home: Map.fetch!(mounts, "/workspace"), cache: Map.fetch!(mounts, "/var/cache/ankole")}
  end

  def volume_exists?(name) do
    case System.cmd(docker_path(), ["volume", "inspect", name], stderr_to_stdout: true) do
      {_output, 0} ->
        true

      {output, 1} ->
        assert output =~ "no such volume", output
        false

      {output, status} ->
        flunk("Docker volume inspect failed (#{status}): #{output}")
    end
  end

  defp remove_container(name) do
    case container_info(name) do
      nil ->
        :ok

      %{status: status} ->
        if status == "running" do
          {output, exit_status} =
            System.cmd(docker_path(), ["stop", "--time", "30", name], stderr_to_stdout: true)

          assert exit_status == 0, output
        end

        {output, exit_status} = System.cmd(docker_path(), ["rm", name], stderr_to_stdout: true)
        assert exit_status == 0, output
    end
  end

  defp remove_provider_resources(provider) do
    assert {:ok, true} =
             wait_until(deadline(60_000), fn ->
               assert {:ok, objects} = Docker.list_instances(provider, :all)

               for object <- objects,
                   do: assert(:ok = Docker.delete_instance(provider, object, :now))

               objects == []
             end)

    {names, 0} =
      System.cmd(
        docker_path(),
        [
          "volume",
          "ls",
          "-q",
          "--filter",
          "label=ankole.installation=#{provider.runtime.installation}",
          "--filter",
          "label=ankole.provider=#{provider.provider_id}"
        ],
        stderr_to_stdout: true
      )

    for name <- String.split(names, "\n", trim: true) do
      {output, status} = System.cmd(docker_path(), ["volume", "rm", name], stderr_to_stdout: true)
      assert status == 0, output
    end

    :ok
  end

  defp env_args(env), do: Enum.flat_map(env, fn {key, value} -> ["-e", "#{key}=#{value}"] end)

  # The socket of the current Docker context; Docker Desktop and Colima do not
  # always provide /var/run/docker.sock.
  defp docker_socket do
    case System.cmd(
           docker_path(),
           ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
           stderr_to_stdout: true
         ) do
      {"unix://" <> path, 0} -> String.trim(path)
      _other -> "/var/run/docker.sock"
    end
  end

  defp docker_image, do: System.fetch_env!("ANKOLE_E2E_WORKER_IMAGE")

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end
end
