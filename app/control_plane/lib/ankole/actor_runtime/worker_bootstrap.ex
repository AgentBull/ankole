defmodule Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Renders external agent computer worker bootstrap data.
  """

  alias Ankole.ActorRuntime.WorkerAuthKeys

  @default_image "ankole-agent-computer:0.1.0"

  @doc """
  Builds the v1 Docker command text without starting Docker.

  Bootstrap remains a rendered command because operator setup owns process
  launch. The control plane only provides the route, database bootstrap URL,
  worker identity, and workspace mount contract.
  """
  @spec docker_run_command(keyword()) :: {:ok, String.t()} | {:error, term()}
  def docker_run_command(opts) do
    with {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id),
         {:ok, database_url} <- fetch_database_url(opts) do
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
           "-e DATABASE_URL=#{shell_escape(database_url)}",
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

  # Pre-creates the three host directories the worker bind-mounts below. Docker
  # would create missing mount sources as root-owned dirs; making them up front
  # (and `&&`-chaining before `docker run`) keeps them owned by the operator.
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

  # Mounts the stable workspace shape expected by the computer worker. The new
  # computer does not read Postgres directly; files under this root are its local
  # runtime view.
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

  defp fetch_database_url(opts) do
    case Keyword.get(opts, :database_url) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _value ->
        {:ok, WorkerAuthKeys.database_url!()}
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
