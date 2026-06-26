defmodule Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Renders external agent computer worker bootstrap data.
  """

  alias Ankole.ActorRuntime.WorkerAuthKeys

  @default_image "ankole-agent-computer:0.1.0"

  @doc """
  Builds the v1 Docker command text without starting Docker.

  Bootstrap remains a rendered command because operator setup owns process
  launch. The control plane provides the RuntimeFabric route, worker pre-auth
  token, worker identity, and shared filesystem mount contract.
  """
  @spec docker_run_command(keyword()) :: {:ok, String.t()} | {:error, term()}
  def docker_run_command(opts) do
    with {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id),
         {:ok, auth_key} <- WorkerAuthKeys.bootstrap_key(worker_id) do
      instance_id =
        Keyword.get_lazy(opts, :worker_instance_id, fn -> "worker-" <> Ecto.UUID.generate() end)

      image = Keyword.get(opts, :image, @default_image)
      workspace_root = Keyword.get(opts, :workspace_root, "$PWD/.ankole-worker")
      container_shared_root = Keyword.get(opts, :container_shared_root, "/workspace/shared")

      container_user_files_root =
        Keyword.get(opts, :container_user_files_root, "#{container_shared_root}/user-files")

      container_installed_skills_root =
        Keyword.get(
          opts,
          :container_installed_skills_root,
          "#{container_shared_root}/skills/agents"
        )

      container_builtin_skills_root =
        Keyword.get(opts, :container_builtin_skills_root, "/repo/app/library/skills")

      workspace_mounts =
        Keyword.get(opts, :workspace_mounts, workspace_mount_args(workspace_root))

      {:ok,
       Enum.join(
         [
           workspace_setup_command(workspace_root),
           "&&",
           "docker run --rm",
           "-e ANKOLE_RUNTIME_FABRIC_ENDPOINT=#{shell_escape(endpoint)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN=#{shell_escape(auth_key.pre_auth_key)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_ID=#{shell_escape(worker_id)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID=#{shell_escape(instance_id)}",
           "-e ANKOLE_WORKSPACE_ROOT=/workspace",
           "-e ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions",
           "-e ANKOLE_SHARED_FS_ROOT=#{shell_escape(container_shared_root)}",
           "-e ANKOLE_USER_FILES_ROOT=#{shell_escape(container_user_files_root)}",
           "-e ANKOLE_AGENT_INSTALLED_SKILLS_ROOT=#{shell_escape(container_installed_skills_root)}",
           "-e ANKOLE_BUILTIN_SKILLS_ROOT=#{shell_escape(container_builtin_skills_root)}",
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
