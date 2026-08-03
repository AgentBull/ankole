defmodule Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Builds the canonical Docker launch contract for Agent Computer workers.

  The contract owns the shared container security settings and, for real
  workers, the RuntimeFabric auth, host connectivity, and Agent Home layout.
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
         contract_version: 3,
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
         {:ok, agents_root} <- fetch_required(opts, :agents_root),
         {:ok, worker_auth_key} <- worker_auth_key(opts) do
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
             "ANKOLE_AGENTS_ROOT" => "/agents",
             "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => endpoint,
             "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => worker_auth_key,
             "WORKER_ID" => worker_id
           },
           host_setup_dirs: [agents_root],
           mounts: [%{source: agents_root, target: "/agents", readonly: false}]
       }}
    end
  end

  defp worker_auth_key(opts) do
    case Keyword.fetch(opts, :auth_key) do
      :error -> WorkerAuthKey.ensure()
      {:ok, auth_key} -> non_empty(auth_key, :auth_key)
    end
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
