defmodule Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Renders external agent computer worker bootstrap data.
  """

  alias Ankole.ActorRuntime.WorkerAuthKey

  @default_image "ankole-agent-computer:0.1.0"

  @doc """
  Builds the v1 Docker command text without starting Docker.

  Bootstrap remains a rendered command because operator setup owns process
  launch. The control plane provides the RuntimeFabric URL, worker identity,
  and shared filesystem mount contract.
  """
  @spec docker_run_command(keyword()) :: {:ok, String.t()} | {:error, term()}
  def docker_run_command(opts) do
    with {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id),
         {:ok, runtime_fabric_url} <- WorkerAuthKey.runtime_fabric_url(endpoint) do
      image = Keyword.get(opts, :image, @default_image)
      workspace_root = Keyword.get(opts, :workspace_root, "$PWD/.ankole-worker")

      workspace_mounts =
        Keyword.get(opts, :workspace_mounts, workspace_mount_args(workspace_root))

      {:ok,
       Enum.join(
         [
           workspace_setup_command(workspace_root),
           "&&",
           "docker run --rm",
           docker_runtime_args(),
           "-e WORKER_ID=#{shell_escape(worker_id)}",
           "-e RUNTIME_FABRIC_URL=#{shell_escape(runtime_fabric_url)}",
           workspace_mounts,
           image
         ],
         " "
       )}
    end
  end

  # Pre-creates the host directories the worker bind-mounts below. Docker
  # would create missing mount sources as root-owned dirs; making them up front
  # (and `&&`-chaining before `docker run`) keeps them owned by the operator.
  defp workspace_setup_command(workspace_root) do
    Enum.join(
      [
        "mkdir -p",
        "#{workspace_root}/shared/user-files",
        "#{workspace_root}/shared/skills/agents",
        "#{workspace_root}/sessions"
      ],
      " "
    )
  end

  # Shared NFS is mounted once under /workspace/shared. The worker creates the
  # per-session logical /workspace view from that shared root.
  defp workspace_mount_args(workspace_root) do
    Enum.join(
      [
        "-v #{workspace_root}/shared:/workspace/shared",
        "-v #{workspace_root}/sessions:/workspace/.sessions"
      ],
      " "
    )
  end

  # The worker command tool always enters bubblewrap. These Docker settings let
  # the nested bwrap probe use a fresh procfs instead of failing startup or
  # downgrading to the weaker container-procfs mode.
  defp docker_runtime_args do
    Enum.join(
      [
        "--cap-add SYS_ADMIN",
        "--security-opt seccomp=unconfined",
        "--security-opt systempaths=unconfined",
        "--add-host host.docker.internal=host-gateway"
      ],
      " "
    )
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
