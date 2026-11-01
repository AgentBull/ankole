defmodule Ankole.AgentWorkers.Providers do
  @moduledoc """
  The owner of Worker provider configuration, credentials, and Agent assignment.

  This module is also the Ash domain of the site `Provider` resource. It is a
  domain separate from `Ankole.AgentWorkers` because a domain has one JSON:API
  router: the providers are in the site API, and the Worker rows of a tenant
  are in the Console API.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

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

  resources do
    resource(Ankole.AgentWorkers.Providers.ConsoleOperations)
    resource(Ankole.AgentWorkers.WorkerEnv.SiteOperations)
    resource(Provider)
  end

  # The site administration API at `/api/v2/site` (`AnkoleWeb.JSONAPI.SiteRouter`).
  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/worker-providers", Ankole.AgentWorkers.Providers.ConsoleOperations do
        route(:get, "/:provider_id/check", :console_check, name: "check_worker_provider")
      end

      base_route "/worker-provider-kinds", Ankole.AgentWorkers.Providers.ConsoleOperations do
        route(:get, "/", :console_kinds, name: "list_worker_provider_kinds")
      end

      base_route "/worker-envs", Ankole.AgentWorkers.WorkerEnv.SiteOperations do
        route(:get, "/", :console_list, name: "list_site_worker_envs")
        route(:put, "/:name", :console_put, name: "update_site_worker_env")
        route(:delete, "/:name", :console_delete, name: "delete_site_worker_env")
        route(:post, "/:name/decryptions", :console_decrypt, name: "decrypt_site_worker_env")
      end

      base_route "/worker-providers", Provider do
        index(:list, name: "list_worker_providers", derive_sort?: false)
        post(:add, name: "create_worker_provider")
        patch(:configure_provider, route: "/:provider_id", name: "update_worker_provider")
        delete(:delete_provider, route: "/:provider_id", name: "delete_worker_provider")
      end
    end
  end

  def list, do: Ankole.Ash.read!(Ash.Query.for_read(Provider, :list))

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
      provider -> with {:ok, _id} <- select_provider(provider), do: check(provider)
    end
  end

  @doc "Selects a provider for a new Agent inside the Agent transaction."
  def select_in_tx(nil) do
    lock_registry(:shared)

    case Provider
         |> Ash.Query.filter(is_default == true)
         |> Ash.Query.lock("FOR KEY SHARE")
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :worker_provider_required}
      provider -> select_provider(provider)
    end
  end

  def select_in_tx(provider_id) when is_binary(provider_id) do
    lock_registry(:shared)

    case Provider
         |> Ash.Query.filter(provider_id == ^provider_id)
         |> Ash.Query.lock("FOR KEY SHARE")
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :worker_provider_not_found}
      provider -> select_provider(provider)
    end
  end

  def select_in_tx(_id), do: {:error, :worker_provider_required}

  defp select_provider(provider) do
    with {:ok, _module} <- ProviderKind.fetch(provider.kind), do: {:ok, provider.provider_id}
  end

  def create(attrs) do
    Repo.transact_top_level(fn -> create_in_tx(attrs) end)
    |> Errors.reason()
  end

  @doc "Creates a provider in the caller's transaction (the composition step of `create/1`)."
  def create_in_tx(attrs) do
    with {:ok, input} <- action_input(attrs) do
      changeset = Ankole.Ash.for_create(Provider, :create, input)

      with :ok <- lock_for_default(changeset),
           do: Ankole.Ash.create(changeset)
    end
  end

  def update(provider_id, attrs) when is_binary(provider_id) and provider_id != "" do
    Repo.transact_top_level(
      fn -> configure_in_tx(provider_id, attrs) end,
      after_commit: &reconcile_workers/1
    )
    |> Errors.reason()
  end

  @doc "Changes a provider in the caller's transaction (the composition step of `update/2`)."
  def configure_in_tx(provider_id, attrs) do
    lock_registry(:exclusive)

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

  def delete(provider_id) when is_binary(provider_id) and provider_id != "" do
    Repo.transact_top_level(fn -> delete_in_tx(provider_id) end)
    |> Errors.reason()
  end

  @doc "Deletes an unassigned provider in the caller's transaction."
  def delete_in_tx(provider_id) do
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
  def assign(agent_uid, provider_id) when is_binary(agent_uid) and agent_uid != "" do
    Repo.transact_top_level(
      fn -> assign_in_tx(agent_uid, provider_id) end,
      after_commit: &ReconcileJob.enqueue/1
    )
    |> Errors.reason()
  end

  @doc "Assigns a provider to an Agent's Worker in the caller's transaction."
  def assign_in_tx(agent_uid, provider_id) do
    with {:ok, provider_id} <- select_in_tx(provider_id),
         %AgentWorker{} = worker <- AgentWorkers.lock_in_tx(agent_uid) do
      Ankole.Ash.update(worker, :assign_provider, %{provider_id: provider_id})
    else
      nil -> {:error, :agent_not_found}
      error -> error
    end
  end

  @doc false
  # Runs the `console_assign_provider` action of the Worker. A missing Agent is
  # not found, and an Agent that has a provider or is being deleted is a
  # conflict.
  def console_assign_in_tx(agent_uid, provider_id) do
    assign_in_tx(agent_uid, provider_id)
    |> Errors.reason()
    |> Errors.wrap(&assign_rejection/1)
  end

  defp assign_rejection(:agent_not_found),
    do: Errors.Invalid.NotFound.exception(resource: AgentWorker)

  defp assign_rejection(:worker_provider_immutable),
    do: {:conflict, "This Agent already has a provider", []}

  defp assign_rejection(:agent_uid_pending_deletion),
    do: {:conflict, "This Agent is being deleted", []}

  defp assign_rejection(reason), do: Ankole.AgentWorkers.Providers.Errors.rejection(reason)

  def provider_ids(agent_uids) do
    [query: [filter: [agent_uid: [in: agent_uids]]]]
    |> AgentWorkers.list_agent_workers!()
    |> Map.new(&{&1.agent_uid, &1.provider_id})
  end

  @doc "Gives a function that checks whether the provider kind is active in this process."
  @spec selectable_fun() :: (Provider.t() -> boolean())
  def selectable_fun, do: &match?({:ok, _id}, select_provider(&1))

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

  defp lock_for_default(changeset) do
    if changeset.valid? do
      mode = if Ash.Changeset.get_attribute(changeset, :is_default), do: :exclusive, else: :shared
      lock_registry(mode)
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
  def lock_registry(:exclusive),
    do: Ankole.AdvisoryLock.lock!(Repo, "worker_providers", hash: :extended)

  def lock_registry(:shared),
    do: Ankole.AdvisoryLock.lock!(Repo, "worker_providers", hash: :extended, shared: true)
end
