defmodule Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Renders external agent computer worker bootstrap data.
  """

  alias Ankole.ActorRuntime.WorkerAuthKey

  @default_image "ghcr.io/agentbull/ankole-agent-computer-worker:main-latest"

  @type docker_mount :: %{
          source: String.t(),
          target: String.t(),
          readonly: boolean()
        }

  @type docker_run_spec :: %{
          worker_id: String.t(),
          runtime_fabric_url: String.t(),
          image: String.t(),
          env: %{String.t() => String.t()},
          docker_runtime_args: [String.t()],
          workspace_root: String.t(),
          workspace_setup_dirs: [String.t()],
          workspace_mounts: [docker_mount()]
        }

  @doc """
  Builds the structured v1 Docker worker bootstrap spec.

  This is the machine-readable form of `docker_run_command/1`. It keeps the
  control plane as the owner of worker auth resolution while letting local
  tooling launch Docker with argv instead of parsing shell text.
  """
  @spec docker_run_spec(keyword()) :: {:ok, docker_run_spec()} | {:error, term()}
  def docker_run_spec(opts) do
    with {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id),
         {:ok, runtime_fabric_url} <- WorkerAuthKey.runtime_fabric_url(endpoint) do
      image = Keyword.get(opts, :image, @default_image)
      workspace_root = Keyword.get(opts, :workspace_root, "$PWD/.ankole-worker")

      {:ok,
       %{
         worker_id: worker_id,
         runtime_fabric_url: runtime_fabric_url,
         image: image,
         env: %{
           "WORKER_ID" => worker_id,
           "RUNTIME_FABRIC_URL" => runtime_fabric_url
         },
         docker_runtime_args: docker_runtime_args(),
         workspace_root: workspace_root,
         workspace_setup_dirs: workspace_setup_dirs(workspace_root),
         workspace_mounts: workspace_mounts(workspace_root)
       }}
    end
  end

  @doc """
  Builds the v1 Docker command text without starting Docker.

  Bootstrap remains a rendered command because operator setup owns process
  launch. The control plane provides the RuntimeFabric URL, worker identity,
  and shared filesystem mount contract.
  """
  @spec docker_run_command(keyword()) :: {:ok, String.t()} | {:error, term()}
  def docker_run_command(opts) do
    with {:ok, spec} <- docker_run_spec(opts) do
      {:ok,
       Enum.join(
         [
           workspace_setup_command(spec.workspace_setup_dirs),
           "&&",
           "docker run --rm",
           Enum.join(spec.docker_runtime_args, " "),
           "-e WORKER_ID=#{shell_escape(spec.worker_id)}",
           "-e RUNTIME_FABRIC_URL=#{shell_escape(spec.runtime_fabric_url)}",
           workspace_mount_args(spec.workspace_mounts),
           spec.image
         ],
         " "
       )}
    end
  end

  # Pre-creates the host directories the worker bind-mounts below. Docker
  # would create missing mount sources as root-owned dirs; making them up front
  # (and `&&`-chaining before `docker run`) keeps them owned by the operator.
  defp workspace_setup_command(dirs) do
    Enum.join(["mkdir -p" | dirs], " ")
  end

  defp workspace_setup_dirs(workspace_root) do
    [
      "#{workspace_root}/shared/user-files",
      "#{workspace_root}/shared/skills/agents",
      "#{workspace_root}/sessions"
    ]
  end

  defp workspace_mounts(workspace_root) do
    [
      %{source: "#{workspace_root}/shared", target: "/workspace/shared", readonly: false},
      %{source: "#{workspace_root}/sessions", target: "/workspace/.sessions", readonly: false}
    ]
  end

  # Shared NFS is mounted once under /workspace/shared. The worker creates the
  # per-session logical /workspace view from that shared root.
  defp workspace_mount_args(mounts) do
    mounts
    |> Enum.map(fn mount ->
      suffix = if mount.readonly, do: ":ro", else: ""
      "-v #{mount.source}:#{mount.target}#{suffix}"
    end)
    |> Enum.join(" ")
  end

  # The worker command tool always enters bubblewrap. These Docker settings let
  # the nested bwrap probe use a fresh procfs instead of failing startup or
  # downgrading to the weaker container-procfs mode.
  defp docker_runtime_args do
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

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  # Single-quotes the value for safe inclusion in the rendered shell command
  # (endpoint, secret, ids may contain shell metacharacters). The `'\"'\"'`
  # sequence is the standard POSIX idiom for embedding a literal single quote
  # inside a single-quoted string: close-quote, escaped-quote, reopen-quote.
  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
