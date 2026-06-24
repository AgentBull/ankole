defmodule Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Renders external agent computer worker bootstrap data.
  """

  alias Ankole.ActorRuntime.Config

  @default_image "ankole-agent-computer-worker:0.1.0"

  @doc """
  Builds the v1 Docker command text without starting Docker.
  """
  @spec docker_run_command(keyword()) :: {:ok, String.t()} | {:error, term()}
  def docker_run_command(opts) do
    with {:ok, token} <- Config.ensure_pre_auth_token(),
         {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id) do
      instance_id =
        Keyword.get_lazy(opts, :worker_instance_id, fn -> "worker-" <> Ecto.UUID.generate() end)

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
           "-e ANKOLE_ACTOR_BUS_ENDPOINT=#{shell_escape(endpoint)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN=#{shell_escape(token)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_ID=#{shell_escape(worker_id)}",
           "-e ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID=#{shell_escape(instance_id)}",
           "-e ANKOLE_WORKSPACE_ROOT=/workspace",
           workspace_mounts,
           image
         ],
         " "
       )}
    end
  end

  defp workspace_setup_command(workspace_root) do
    Enum.join(
      [
        "mkdir -p",
        "#{workspace_root}/user-files",
        "#{workspace_root}/temp",
        "#{workspace_root}/library-containers"
      ],
      " "
    )
  end

  defp workspace_mount_args(workspace_root) do
    Enum.join(
      [
        "-v #{workspace_root}/user-files:/workspace/user-files",
        "-v #{workspace_root}/temp:/workspace/temp",
        "-v #{workspace_root}/library-containers:/workspace/library-containers"
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

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
