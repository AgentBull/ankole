defmodule Ankole.AgentWorkers.ProviderKind do
  @moduledoc """
  The platform boundary for Worker instances and Agent storage.

  A kind translates requests. Reconciliation owns lifecycle decisions. A
  successful delete request does not prove absence; only a subsequent list
  can permit another instance to write the Agent's storage.

  Agent-scoped callbacks run in the owning `Ankole.Repo` tenant context.
  Site-wide inventory returns the tenant with each observed Agent so callers
  can reconcile equal names independently.
  """

  alias Ankole.AgentWorkers.ProviderKind.Definition
  alias Ankole.AgentWorkers.Providers.Runtime
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec

  @contract_id "agent_workers.provider_kind"
  @cache_key {__MODULE__, :registry}

  @type observation :: %{
          optional(:instance_present?) => boolean(),
          optional(:sandbox_name) => String.t(),
          required(:tenant_id) => String.t() | nil,
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

  @callback check(Runtime.t()) :: :ok | {:error, term()}
  @callback prepare_image(Runtime.t(), String.t()) :: :ok | {:pending, term()} | {:error, term()}
  @callback prepare_storage(Runtime.t(), String.t()) :: :ok | {:error, term()}
  @callback create_instance(Runtime.t(), AgentWorkerSpec.t()) ::
              {:ok, String.t() | nil} | {:rejected, term()} | {:error, term()}
  @callback delete_instance(Runtime.t(), observation(), :graceful | :now) ::
              :ok | {:error, term()}
  @callback pause_instance(Runtime.t(), observation()) :: :ok | {:error, term()}
  @callback resume_instance(Runtime.t(), observation()) :: :ok | {:error, term()}
  @callback list_instances(Runtime.t(), String.t() | :all) ::
              {:ok, [observation()]} | {:error, term()}
  @callback current_storage_ref(Runtime.t(), String.t()) ::
              {:ok, map() | nil, String.t() | nil} | {:error, term()}
  @callback delete_cache(Runtime.t(), String.t()) :: :ok | {:error, term()}
  @callback delete_storage(Runtime.t(), String.t(), map() | nil) ::
              {:ok, map() | nil} | {:pending, map() | nil} | {:error, term()}

  @kinds %{
    "docker" => Ankole.AgentWorkers.Docker,
    "kubernetes" => Ankole.AgentWorkers.Kubernetes,
    "cloudflare" => Ankole.AgentWorkers.Cloudflare,
    "lambda" => Ankole.AgentWorkers.Lambda
  }

  @doc false
  def refresh_from_specs(discovered, active) do
    active_ids = MapSet.new(active, & &1.id)

    plugin_kinds =
      for plugin <- Enum.sort_by(discovered, &MapSet.member?(active_ids, &1.id)),
          %{contract_id: @contract_id, id: id, module: module} <- plugin.adapter_declarations,
          into: %{},
          do:
            {id,
             %{
               module: module,
               plugin_id: plugin.id,
               active?: MapSet.member?(active_ids, plugin.id)
             }}

    builtins =
      Map.new(@kinds, fn {id, module} ->
        {id, %{module: module, plugin_id: nil, active?: true}}
      end)

    registry = Map.merge(plugin_kinds, builtins)
    :persistent_term.put(@cache_key, registry)
    registry
  end

  @doc false
  def registry, do: :persistent_term.get(@cache_key)

  @spec all() :: [module()]
  def all do
    for {_id, %{module: module, active?: true}} <- Enum.sort(registry()), do: module
  end

  @spec fetch(String.t()) :: {:ok, module()} | {:error, term()}
  def fetch(kind) do
    case registry()[kind] do
      %{module: module, active?: true} -> {:ok, module}
      %{plugin_id: plugin_id} -> {:error, {:worker_provider_plugin_inactive, plugin_id}}
      nil -> {:error, :unknown_worker_provider_kind}
    end
  end

  @doc false
  def validate_adapter_declaration(%{id: id, module: module})
      when is_binary(id) and is_atom(module) do
    with :ok <- validate_builtin_override(id),
         :ok <- validate_module(module) do
      validate_definition(id, module.definition())
    end
  end

  def validate_adapter_declaration(declaration),
    do: {:error, {:invalid_worker_provider_declaration, declaration}}

  defp validate_builtin_override(id) do
    if Map.has_key?(@kinds, id),
      do: {:error, {:builtin_worker_provider_kind, id}},
      else: :ok
  end

  defp validate_module(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:worker_provider_module_unavailable, module, reason}}
    end
  end

  defp validate_definition(id, %Definition{kind: id}), do: :ok

  defp validate_definition(id, %Definition{kind: actual}),
    do: {:error, {:worker_provider_kind_mismatch, id, actual}}

  defp validate_definition(id, definition),
    do: {:error, {:invalid_worker_provider_definition, id, definition}}

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
    not is_nil(worker.generation) and observation.generation == worker.generation and
      (is_nil(worker.instance_ref) or observation.instance_ref == worker.instance_ref)
  end

  @spec storage_name(String.t(), String.t()) :: String.t()
  def storage_name(installation, agent_uid), do: "ankole-#{installation}-#{agent_hash(agent_uid)}"

  @spec instance_name(String.t(), String.t(), String.t()) :: String.t()
  def instance_name(installation, agent_uid, generation),
    do: storage_name(installation, agent_uid) <> "-" <> generation

  def agent_hash(uid), do: agent_hash(Ankole.Repo.tenant_id!(), uid)
  def agent_hash(tenant_id, uid), do: hash16(tenant_id <> ":" <> uid)

  @spec hash16(String.t()) :: String.t()
  def hash16(agent_uid),
    do: :sha256 |> :crypto.hash(agent_uid) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
