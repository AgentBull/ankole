defmodule Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Builds the canonical Docker launch contract for Agent Computer workers.

  The contract owns the shared container security settings and, for real
  workers, the RuntimeFabric auth, host connectivity, and workspace layout.
  Launch adapters translate the contract and add only their local lifecycle,
  source-mount, and command differences.
  """

  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.Spec

  @doc """
  Builds the shared Agent Computer container contract without worker identity.

  Package tests use this contract because they run inside the worker image but
  do not connect a worker process to RuntimeFabric. Published control-plane
  images provide their same-revision worker through
  `ANKOLE_AGENT_COMPUTER_IMAGE`; source callers must pass `:image` explicitly.
  """
  @spec container_spec(keyword()) :: {:ok, Spec.t()} | {:error, term()}
  def container_spec(opts \\ []) do
    image = Keyword.get(opts, :image) || System.get_env("ANKOLE_AGENT_COMPUTER_IMAGE")

    with {:ok, image} <- non_empty(image, :image) do
      {:ok,
       %Spec{
         contract_version: 2,
         kind: :container,
         image: image,
         docker: %{
           cap_add: ["SYS_ADMIN"],
           security_opts: ["seccomp=unconfined", "systempaths=unconfined"],
           extra_hosts: []
         },
         env: %{},
         host_setup_dirs: [],
         mounts: []
       }}
    end
  end

  @doc """
  Builds the complete Agent Computer worker launch contract.

  By default the global worker auth key is resolved through AppConfigure. E2E
  routers may pass `:auth_key` explicitly so the same contract constructs both
  successful and rejected worker credentials.
  """
  @spec worker_spec(keyword()) :: {:ok, Spec.t()} | {:error, term()}
  def worker_spec(opts) do
    with {:ok, spec} <- container_spec(opts),
         {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, worker_id} <- fetch_required(opts, :worker_id),
         {:ok, workspace_root} <- fetch_required(opts, :workspace_root),
         {:ok, runtime_fabric_url} <- runtime_fabric_url(endpoint, opts) do
      {:ok,
       %{
         spec
         | kind: :worker,
           docker: %{
             spec.docker
             | extra_hosts: [
                 %{host: "host.docker.internal", address: "host-gateway"}
               ]
           },
           env: %{
             "WORKER_ID" => worker_id,
             "RUNTIME_FABRIC_URL" => runtime_fabric_url
           },
           host_setup_dirs: workspace_setup_dirs(workspace_root),
           mounts: workspace_mounts(workspace_root)
       }}
    end
  end

  defp runtime_fabric_url(endpoint, opts) do
    case Keyword.fetch(opts, :auth_key) do
      :error -> WorkerAuthKey.runtime_fabric_url(endpoint)
      {:ok, auth_key} -> WorkerAuthKey.runtime_fabric_url(endpoint, auth_key)
    end
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

  defp fetch_required(opts, key) do
    opts
    |> Keyword.get(key)
    |> non_empty(key, {:missing, key})
  end

  defp non_empty(value, key, error \\ nil)

  defp non_empty(value, _key, _error) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty(_value, key, nil), do: {:error, {:invalid, key}}
  defp non_empty(_value, _key, error), do: {:error, error}
end
