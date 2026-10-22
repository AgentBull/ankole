defmodule Ankole.AgentWorkers.Providers do
  @moduledoc "The owner of Worker provider configuration, credentials, and Agent assignment."

  import Ecto.Query
  require Ash.Query
  alias Ankole.Attrs
  alias Ankole.Repo
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
    with %AgentWorker{} = worker <- Repo.get(AgentWorker, agent_uid) do
      {:ok, Map.get(worker.instance_settings, "endpoints", %{})}
    else
      nil -> {:error, :worker_provider_missing}
      error -> error
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

    case repo.one(from(p in Provider, where: p.is_default, lock: "FOR KEY SHARE")) do
      nil -> {:error, :worker_provider_required}
      provider -> select_provider(repo, provider)
    end
  end

  def select_in_tx(repo, provider_id) when is_binary(provider_id) do
    lock_registry(repo, :shared)

    case repo.one(
           from(p in Provider, where: p.provider_id == ^provider_id, lock: "FOR KEY SHARE")
         ) do
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

  @doc "Locks the provider registry and checks references only for disabled Worker kinds."
  def validate_disabled_kinds(_repo, disabled_kinds) when map_size(disabled_kinds) == 0, do: :ok

  def validate_disabled_kinds(repo, disabled_kinds) do
    lock_registry(repo, :exclusive)
    kinds = Map.keys(disabled_kinds)

    assigned =
      Repo.across_tenants(fn ->
        repo.one(
          from(w in AgentWorker,
            join: p in Provider,
            on: p.provider_id == w.provider_id,
            where: p.kind in ^kinds,
            select: {p.kind, p.provider_id},
            limit: 1
          )
        )
      end)

    case assigned do
      nil ->
        :ok

      {kind, id} ->
        {:error, {:worker_provider_plugin_in_use, Map.fetch!(disabled_kinds, kind), id}}
    end
  end

  def create(attrs) do
    Repo.transact(&create_in_tx(&1, attrs))
  end

  @doc false
  def create_in_tx(repo, attrs) do
    with {:ok, input} <- action_input(attrs) do
      changeset = Ankole.Ash.for_create(Provider, :create, input)

      if changeset.valid? do
        mode =
          if Ash.Changeset.get_attribute(changeset, :is_default), do: :exclusive, else: :shared

        lock_registry(repo, mode)
        set_default_in_tx(changeset)
      end

      Ankole.Ash.create(changeset)
    end
  end

  def update(provider_id, attrs) do
    result =
      Repo.transact(fn repo ->
        lock_registry(repo, :exclusive)

        with %Provider{} = provider <-
               repo.one(
                 from(p in Provider, where: p.provider_id == ^provider_id, lock: "FOR UPDATE")
               ),
             {:ok, input} <- action_input(attrs) do
          changeset = Ankole.Ash.for_update(provider, :configure, input)
          if changeset.valid?, do: set_default_in_tx(changeset)

          with {:ok, updated} <- Ankole.Ash.update(changeset) do
            :ok = Ankole.AgentWorkers.clear_provider_rejections_in_tx(provider_id)

            {:ok, updated}
          end
        else
          nil -> {:error, :worker_provider_not_found}
          error -> error
        end
      end)

    case result do
      {:ok, _provider} ->
        Repo.across_tenants(fn ->
          Repo.all(from(w in AgentWorker, where: w.provider_id == ^provider_id))
        end)
        |> Enum.each(&ReconcileJob.enqueue/1)

      _error ->
        :ok
    end

    result
  end

  def delete(provider_id) do
    Repo.transact(fn repo ->
      with %Provider{} = provider <-
             repo.one(
               from(p in Provider, where: p.provider_id == ^provider_id, lock: "FOR UPDATE")
             ),
           false <-
             Repo.across_tenants(fn ->
               repo.exists?(from(w in AgentWorker, where: w.provider_id == ^provider_id))
             end) do
        Ankole.Ash.destroy(provider, :remove)
      else
        nil -> {:error, :worker_provider_not_found}
        true -> {:error, :worker_provider_in_use}
      end
    end)
  end

  @doc "Assigns a migrated Worker exactly once."
  def assign(agent_uid, provider_id) do
    result =
      Repo.transact(fn repo ->
        with {:ok, provider_id} <- select_in_tx(repo, provider_id),
             %AgentWorker{} = worker <-
               Ankole.AgentWorkers.lock_in_tx(repo, agent_uid) do
          Ankole.Ash.update(worker, :assign_provider, %{provider_id: provider_id})
        else
          nil -> {:error, :agent_not_found}
          error -> error
        end
      end)

    if match?({:ok, _}, result), do: ReconcileJob.enqueue(agent_uid)
    result
  end

  def provider_ids(agent_uids) do
    Repo.all(
      from(w in AgentWorker,
        where: w.agent_uid in ^agent_uids,
        select: {w.agent_uid, w.provider_id}
      )
    )
    |> Map.new()
  end

  def projection(provider, agent_count \\ nil) do
    agent_count =
      agent_count ||
        Repo.across_tenants(fn ->
          Repo.aggregate(
            from(w in AgentWorker, where: w.provider_id == ^provider.provider_id),
            :count
          )
        end)

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
    counts =
      Repo.across_tenants(fn ->
        Repo.all(
          from(w in AgentWorker,
            group_by: w.provider_id,
            select: {w.provider_id, count(w.agent_uid)}
          )
        )
      end)
      |> Map.new()

    enabled = configured_plugins(Repo)
    Enum.map(list(), &projection(&1, Map.get(counts, &1.provider_id, 0), enabled))
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

  defp set_default_in_tx(changeset) do
    if Ash.Changeset.get_attribute(changeset, :is_default) do
      id = Ash.Changeset.get_attribute(changeset, :id)

      result =
        Provider
        |> Ash.Query.filter(is_default == true and id != ^id)
        |> Ankole.Ash.bulk_update(:unset_default, %{}, strategy: [:atomic], return_errors?: true)

      case result do
        %{status: :success} -> :ok
        %{errors: [error | _]} -> Repo.rollback(error)
      end
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
