defmodule Ankole.AgentWorkers.Providers do
  @moduledoc "The owner of Worker provider configuration, credentials, and Agent assignment."

  require Ash.Query
  alias Ankole.Attrs
  alias Ankole.Errors
  alias Ankole.Repo
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.ProviderKind

  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.Providers.Credentials
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.Providers.Runtime

  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.AgentWorker

  @write_keys ~w(provider_id kind display_name config credentials is_default)

  def list do
    Provider |> Ash.Query.sort(:provider_id) |> Ankole.Ash.read!()
  end

  def fetch(provider_id) when is_binary(provider_id) do
    case Ankole.Ash.read_one!(Ash.Query.filter(Provider, provider_id == ^provider_id)) do
      nil -> {:error, :worker_provider_not_found}
      provider -> {:ok, provider}
    end
  end

  def fetch(_id), do: {:error, :worker_provider_missing}

  @doc "Validates only this row and loads its runtime settings and secrets."
  def load(%Provider{} = provider) do
    with {:ok, kind} <- ProviderKind.fetch(provider.kind),
         definition = kind.definition(),
         {:ok, settings} <- Configuration.parse(definition.schema, provider.config),
         {:ok, secrets} <- Credentials.load(provider),
         :ok <- Credentials.validate(kind, definition, settings, secrets),
         {:ok, runtime} <- Config.fetch() do
      {:ok,
       %Runtime{
         id: provider.id,
         provider_id: provider.provider_id,
         kind: provider.kind,
         settings: settings,
         secrets: secrets,
         runtime: runtime,
         settings_digest: Configuration.digest(definition.schema, settings)
       }}
    end
  end

  def load(provider_id) do
    with {:ok, provider} <- fetch(provider_id), do: load(provider)
  end

  def check(provider_id) do
    with {:ok, provider} <- load(provider_id),
         {:ok, kind} <- ProviderKind.fetch(provider.kind) do
      kind.check(provider)
    end
  end

  @doc "Returns the connection addresses selected for this Agent's current generation."
  def connection_endpoints(agent_uid) do
    case AgentWorkers.get_agent_worker!(agent_uid) do
      %AgentWorker{} = worker -> {:ok, Map.get(worker.instance_settings, "endpoints", %{})}
      nil -> {:error, :worker_provider_missing}
    end
  end

  def default_status do
    case Ankole.Ash.read_one!(Ash.Query.filter(Provider, is_default == true)) do
      nil -> {:error, :worker_provider_required}
      provider -> with {:ok, _id} <- select_provider(Repo, provider), do: check(provider)
    end
  end

  @doc "Selects a provider for a new Agent inside the Agent transaction."
  def select_in_tx(repo, nil) do
    lock_registry(repo, :shared)

    case Provider
         |> Ash.Query.filter(is_default == true)
         |> Ash.Query.lock("FOR KEY SHARE")
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :worker_provider_required}
      provider -> select_provider(repo, provider)
    end
  end

  def select_in_tx(repo, provider_id) when is_binary(provider_id) do
    lock_registry(repo, :shared)

    case Provider
         |> Ash.Query.filter(provider_id == ^provider_id)
         |> Ash.Query.lock("FOR KEY SHARE")
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :worker_provider_not_found}
      provider -> select_provider(repo, provider)
    end
  end

  def select_in_tx(_repo, _id), do: {:error, :worker_provider_required}

  defp select_provider(repo, provider) do
    enabled =
      case ProviderKind.registry()[provider.kind] do
        %{active?: true, plugin_id: plugin_id} when not is_nil(plugin_id) ->
          configured_plugins(repo)

        _kind ->
          {:ok, []}
      end

    validate_selection(provider, enabled)
  end

  defp validate_selection(provider, enabled) do
    with {:ok, _module} <- ProviderKind.fetch(provider.kind),
         :ok <- ensure_plugin_selected(ProviderKind.registry()[provider.kind].plugin_id, enabled) do
      {:ok, provider.provider_id}
    end
  end

  defp configured_plugins(repo),
    do: Ankole.AppConfigure.get_in_tx(repo, Ankole.Plugins.enabled_ids_definition())

  defp ensure_plugin_selected(nil, _enabled), do: :ok

  defp ensure_plugin_selected(plugin_id, {:ok, enabled}) do
    if plugin_id in enabled,
      do: :ok,
      else: {:error, {:worker_provider_plugin_inactive, plugin_id}}
  end

  defp ensure_plugin_selected(_plugin_id, error), do: error

  @doc """
  Stops a Plugin selection that removes a Worker kind still in use.

  `Ankole.Plugins.Contracts` calls it in the transaction that writes the enable
  list. Only a change that removes Worker kinds takes the exclusive registry
  lock and checks the Worker rows of every tenant.
  """
  @spec veto_disable_in_tx(module(), [String.t()], [String.t()]) :: :ok | {:error, term()}
  def veto_disable_in_tx(repo, previous_ids, enabled_ids) do
    ProviderKind.registry()
    |> ProviderKind.disabled_kinds(previous_ids, enabled_ids)
    |> validate_disabled_kinds(repo)
  end

  defp validate_disabled_kinds(disabled_kinds, _repo) when map_size(disabled_kinds) == 0, do: :ok

  defp validate_disabled_kinds(disabled_kinds, repo) do
    lock_registry(repo, :exclusive)
    kinds = Map.keys(disabled_kinds)
    providers = Provider |> Ash.Query.filter(kind in ^kinds) |> Ankole.Ash.read!()

    case AgentWorkers.assigned_worker(Enum.map(providers, & &1.provider_id)) do
      nil ->
        :ok

      %AgentWorker{provider_id: id} ->
        kind = Enum.find_value(providers, &(&1.provider_id == id and &1.kind))
        {:error, {:worker_provider_plugin_in_use, Map.fetch!(disabled_kinds, kind), id}}
    end
  end

  def create(attrs), do: Errors.reason(AgentWorkers.add_provider(attrs))

  @doc false
  def create_in_tx(repo, attrs) do
    with {:ok, input} <- action_input(attrs) do
      changeset = Ankole.Ash.for_create(Provider, :create, input)

      with :ok <- lock_for_default(repo, changeset),
           do: Ankole.Ash.create(changeset)
    end
  end

  def update(provider_id, attrs),
    do: Errors.reason(AgentWorkers.configure_provider(provider_id, attrs))

  @doc false
  def configure_in_tx(%{provider_id: provider_id, attrs: attrs}) do
    lock_registry(Repo, :exclusive)

    with %Provider{} = provider <- lock_provider(provider_id),
         {:ok, input} <- action_input(attrs),
         changeset = Ankole.Ash.for_update(provider, :configure, input),
         :ok <- unset_other_defaults(changeset),
         {:ok, updated} <- Ankole.Ash.update(changeset),
         :ok <- AgentWorkers.clear_provider_rejections_in_tx(provider_id) do
      {:ok, updated}
    else
      nil -> {:error, :worker_provider_not_found}
      error -> error
    end
  end

  @doc false
  def reconcile_workers(%Provider{provider_id: provider_id}),
    do: provider_id |> AgentWorkers.provider_workers() |> Enum.each(&ReconcileJob.enqueue/1)

  def delete(provider_id), do: Errors.reason(AgentWorkers.delete_provider(provider_id))

  @doc false
  def delete_in_tx(%{provider_id: provider_id}) do
    case lock_provider(provider_id) do
      nil ->
        {:error, :worker_provider_not_found}

      provider ->
        if AgentWorkers.assigned_worker([provider_id]),
          do: {:error, :worker_provider_in_use},
          else: Ankole.Ash.destroy(provider, :remove)
    end
  end

  @doc "Assigns a migrated Worker exactly once."
  def assign(agent_uid, provider_id),
    do: Errors.reason(AgentWorkers.assign_worker_provider(agent_uid, provider_id))

  @doc false
  def assign_in_tx(%{agent_uid: agent_uid, provider_id: provider_id}) do
    with {:ok, provider_id} <- select_in_tx(Repo, provider_id),
         %AgentWorker{} = worker <- AgentWorkers.lock_in_tx(Repo, agent_uid) do
      Ankole.Ash.update(worker, :assign_provider, %{provider_id: provider_id})
    else
      nil -> {:error, :agent_not_found}
      error -> error
    end
  end

  def provider_ids(agent_uids) do
    [query: [filter: [agent_uid: [in: agent_uids]]]]
    |> AgentWorkers.list_agent_workers!()
    |> Map.new(&{&1.agent_uid, &1.provider_id})
  end

  def projection(provider, agent_count \\ nil) do
    agent_count = agent_count || AgentWorkers.provider_worker_count(provider.provider_id)
    projection(provider, agent_count, configured_plugins(Repo))
  end

  defp projection(provider, agent_count, enabled) do
    %{
      provider_id: provider.provider_id,
      kind: provider.kind,
      display_name: provider.display_name,
      config: provider.config,
      is_default: provider.is_default,
      agent_count: agent_count,
      selectable: match?({:ok, _id}, validate_selection(provider, enabled)),
      credentials: Map.new(provider.credentials, fn {name, _ciphertext} -> {name, "********"} end)
    }
  end

  def list_projections do
    enabled = configured_plugins(Repo)

    Enum.map(
      list(),
      &projection(&1, AgentWorkers.provider_worker_count(&1.provider_id), enabled)
    )
  end

  defp action_input(attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    case Map.keys(attrs) -- @write_keys do
      [] ->
        {credentials, attrs} = Map.pop(attrs, "credentials", %{})
        {:ok, Map.put(attrs, "credential_input", credentials)}

      unknown ->
        {:error, {:unknown_worker_provider_fields, unknown}}
    end
  end

  defp lock_provider(provider_id) do
    Provider
    |> Ash.Query.filter(provider_id == ^provider_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp lock_for_default(repo, changeset) do
    if changeset.valid? do
      mode = if Ash.Changeset.get_attribute(changeset, :is_default), do: :exclusive, else: :shared
      lock_registry(repo, mode)
      unset_other_defaults(changeset)
    else
      :ok
    end
  end

  defp unset_other_defaults(changeset) do
    if changeset.valid? and Ash.Changeset.get_attribute(changeset, :is_default) do
      id = Ash.Changeset.get_attribute(changeset, :id)

      case Provider
           |> Ash.Query.filter(is_default == true and id != ^id)
           |> Ankole.Ash.update_where(:unset_default) do
        {:ok, _providers} -> :ok
        {:error, _error} = error -> error
      end
    else
      :ok
    end
  end

  # All creates exclude seed import. Only default changes need to exclude
  # each other; independent non-default creates can hold the shared lock.
  @doc false
  def lock_registry(repo, :exclusive),
    do: Ankole.AdvisoryLock.lock!(repo, "worker_providers", hash: :extended)

  def lock_registry(repo, :shared),
    do: Ankole.AdvisoryLock.lock!(repo, "worker_providers", hash: :extended, shared: true)
end
