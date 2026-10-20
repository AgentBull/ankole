defmodule Ankole.AgentWorkers.ProviderKind do
  @moduledoc """
  The platform boundary for Worker instances and Agent storage.

  A kind translates requests. Reconciliation owns lifecycle decisions. A
  successful delete request does not prove absence; only a subsequent list
  can permit another instance to write the Agent's storage.
  """

  alias Ankole.AgentWorkers.ProviderKind.Definition
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec

  @type observation :: %{
          optional(:instance_present?) => boolean(),
          optional(:sandbox_name) => String.t(),
          required(:agent_uid) => String.t() | nil,
          required(:generation) => String.t() | nil,
          required(:instance_ref) => String.t() | nil,
          required(:phase) => :starting | :running | :paused | :terminating | :exited,
          required(:reason) => String.t() | nil,
          required(:started_at) => DateTime.t() | nil
        }

  @callback definition() :: Definition.t()
  @callback validate_credentials(map(), map()) :: :ok | {:error, term()}
  @callback prepare_credentials(Provider.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback instance_lifetime(map()) :: pos_integer()
  @optional_callbacks validate_credentials: 2, prepare_credentials: 3, instance_lifetime: 1

  @callback check(Provider.t()) :: :ok | {:error, term()}
  @callback prepare_image(Provider.t(), String.t()) :: :ok | {:pending, term()} | {:error, term()}
  @callback prepare_storage(Provider.t(), String.t()) :: :ok | {:error, term()}
  @callback create_instance(Provider.t(), AgentWorkerSpec.t()) ::
              {:ok, String.t() | nil} | {:rejected, term()} | {:error, term()}
  @callback delete_instance(Provider.t(), observation(), :graceful | :now) ::
              :ok | {:error, term()}
  @callback pause_instance(Provider.t(), observation()) :: :ok | {:error, term()}
  @callback resume_instance(Provider.t(), observation()) :: :ok | {:error, term()}
  @callback list_instances(Provider.t(), String.t() | :all) ::
              {:ok, [observation()]} | {:error, term()}
  @callback current_storage_ref(Provider.t(), String.t()) ::
              {:ok, map() | nil, String.t() | nil} | {:error, term()}
  @callback delete_cache(Provider.t(), String.t()) :: :ok | {:error, term()}
  @callback delete_storage(Provider.t(), String.t(), map() | nil) ::
              {:ok, map() | nil} | {:pending, map() | nil} | {:error, term()}

  @kinds %{
    "docker" => Ankole.AgentWorkers.Docker,
    "kubernetes" => Ankole.AgentWorkers.Kubernetes,
    "cloudflare" => Ankole.AgentWorkers.Cloudflare,
    "vercel" => Ankole.AgentWorkers.Vercel,
    "lambda" => Ankole.AgentWorkers.Lambda,
    "function_compute" => Ankole.AgentWorkers.FunctionCompute
  }

  @spec all() :: [module()]
  def all, do: @kinds |> Enum.sort() |> Enum.map(&elem(&1, 1))

  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_worker_provider_kind}
  def fetch(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_worker_provider_kind}
    end
  end

  @doc "The lifetime of a generation, from its saved instance settings."
  @spec instance_lifetime(module(), map()) :: pos_integer() | nil
  def instance_lifetime(kind, settings) do
    if function_exported?(kind, :instance_lifetime, 1),
      do: kind.instance_lifetime(settings),
      else: kind.definition().max_instance_lifetime
  end

  @doc "A partial resource, such as a Secret without its Pod, is not an observed instance."
  def instance_present?(observation), do: Map.get(observation, :instance_present?, true)

  @doc "A saved instance reference selects one instance when a generation has repeated creates."
  def current_instance?(worker, observation) do
    observation.generation == worker.generation and
      (is_nil(worker.instance_ref) or observation.instance_ref == worker.instance_ref)
  end

  @spec storage_name(String.t(), String.t()) :: String.t()
  def storage_name(installation, agent_uid), do: "ankole-#{installation}-#{hash16(agent_uid)}"

  @spec instance_name(String.t(), String.t(), String.t()) :: String.t()
  def instance_name(installation, agent_uid, generation),
    do: storage_name(installation, agent_uid) <> "-" <> generation

  @spec hash16(String.t()) :: String.t()
  def hash16(agent_uid),
    do: :sha256 |> :crypto.hash(agent_uid) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
