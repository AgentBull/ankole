defmodule Ankole.ActorRuntime.WorkerBootstrap.Docker do
  @moduledoc """
  Translates a worker bootstrap contract into Docker argv or operator shell text.
  """

  alias Ankole.ActorRuntime.WorkerBootstrap.Spec

  @spec argv(Spec.t(), keyword()) :: [String.t()]
  def argv(%Spec{} = spec, opts \\ []) do
    env = merge_additional_env(spec, Keyword.get(opts, :additional_env, %{}))
    mounts = spec.mounts ++ Keyword.get(opts, :additional_mounts, [])

    ["run", "--rm"] ++
      name_args(Keyword.get(opts, :name)) ++
      label_args(Keyword.get(opts, :labels, [])) ++
      docker_runtime_args(spec.docker) ++
      env_args(env) ++
      mount_args(mounts) ++
      [spec.image] ++ Keyword.get(opts, :command, [])
  end

  @spec shell_command(Spec.t(), keyword()) :: String.t()
  def shell_command(%Spec{} = spec, opts \\ []) do
    docker = shell_join(["docker" | argv(spec, opts)])

    case spec.host_setup_dirs do
      [] -> docker
      dirs -> shell_join(["mkdir", "-p" | dirs]) <> " && " <> docker
    end
  end

  defp name_args(nil), do: []
  defp name_args(name), do: ["--name", name]

  defp merge_additional_env(%Spec{kind: :worker, env: env}, additional_env) do
    case Map.keys(env) -- Map.keys(additional_env) do
      keys when length(keys) == map_size(env) -> Map.merge(env, additional_env)
      _keys -> raise ArgumentError, "worker launch adapters cannot replace canonical environment"
    end
  end

  defp merge_additional_env(%Spec{env: env}, additional_env), do: Map.merge(env, additional_env)

  defp label_args(labels) do
    Enum.flat_map(labels, fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  defp docker_runtime_args(docker) do
    Enum.flat_map(docker.cap_add, &["--cap-add", &1]) ++
      Enum.flat_map(docker.security_opts, &["--security-opt", &1]) ++
      Enum.flat_map(docker.extra_hosts, fn host ->
        ["--add-host", "#{host.host}=#{host.address}"]
      end)
  end

  defp env_args(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  defp mount_args(mounts) do
    Enum.flat_map(mounts, fn mount ->
      ["--mount", bind_mount(mount)]
    end)
  end

  defp bind_mount(mount) do
    readonly = if mount.readonly, do: ",readonly", else: ""
    "type=bind,src=#{mount.source},dst=#{mount.target}#{readonly}"
  end

  defp shell_join(args), do: Enum.map_join(args, " ", &shell_escape/1)

  defp shell_escape(value) do
    case Regex.match?(~r/^[A-Za-z0-9_@%+=:,\.\/-]+$/, value) do
      true -> value
      false -> "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end
end
