defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers do
  @moduledoc "The owner of Worker provider configuration, credentials, and Agent assignment."

  import Ecto.Query
  alias Ankole.Attrs
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Config
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{
    Configuration,
    Credentials,
    Provider
  }

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  @write_keys ~w(provider_id kind display_name config credentials is_default)

  def list do
    Repo.all(from p in Provider, order_by: p.provider_id)
  end

  def fetch(provider_id) when is_binary(provider_id) do
    case Repo.get_by(Provider, provider_id: provider_id) do
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
       %{
         provider
         | settings: settings,
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
    case Repo.one(from p in Provider, where: p.is_default) do
      nil -> {:error, :worker_provider_required}
      provider -> check(provider)
    end
  end

  @doc "Selects a provider for a new Agent inside the Agent transaction."
  def select_in_tx(repo, nil) do
    case repo.one(from p in Provider, where: p.is_default, lock: "FOR KEY SHARE") do
      nil -> {:error, :worker_provider_required}
      provider -> {:ok, provider.provider_id}
    end
  end

  def select_in_tx(repo, provider_id) when is_binary(provider_id) do
    case repo.one(from p in Provider, where: p.provider_id == ^provider_id, lock: "FOR KEY SHARE") do
      nil -> {:error, :worker_provider_not_found}
      provider -> {:ok, provider.provider_id}
    end
  end

  def select_in_tx(_repo, _id), do: {:error, :worker_provider_required}

  def create(attrs) do
    Repo.transact(&create_in_tx(&1, attrs))
  end

  @doc false
  def create_in_tx(repo, attrs) do
    provider = %Provider{id: Ankole.Ecto.UUIDv7.autogenerate()}

    with {:ok, changeset} <- changeset(provider, attrs) do
      mode = if Ecto.Changeset.get_field(changeset, :is_default), do: :exclusive, else: :shared
      lock_registry(repo, mode)
      set_default_in_tx(repo, changeset)
      repo.insert(changeset)
    end
  end

  def update(provider_id, attrs) do
    result =
      Repo.transact(fn repo ->
        lock_registry(repo, :exclusive)

        with %Provider{} = provider <-
               repo.one(
                 from p in Provider, where: p.provider_id == ^provider_id, lock: "FOR UPDATE"
               ),
             {:ok, changeset} <- changeset(provider, attrs) do
          set_default_in_tx(repo, changeset)

          with {:ok, updated} <- repo.update(changeset) do
            Repo.across_tenants(fn ->
              repo.update_all(
                from(w in AgentWorker,
                  where: w.provider_id == ^provider_id and w.last_error_kind == "rejected"
                ),
                set: AgentWorker.error_fields(nil, nil)
              )
            end)

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
          Repo.all(from w in AgentWorker, where: w.provider_id == ^provider_id)
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
               from p in Provider, where: p.provider_id == ^provider_id, lock: "FOR UPDATE"
             ),
           false <-
             Repo.across_tenants(fn ->
               repo.exists?(from w in AgentWorker, where: w.provider_id == ^provider_id)
             end) do
        repo.delete(Provider.changeset(provider, %{}))
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
               Ankole.SignalsGateway.ActorRuntime.AgentWorkers.lock_in_tx(repo, agent_uid) do
          cond do
            worker.provider_id != nil ->
              {:error, :worker_provider_immutable}

            worker.state == "deleting" ->
              {:error, :agent_uid_pending_deletion}

            true ->
              repo.update(
                Ecto.Changeset.change(
                  worker,
                  [provider_id: provider_id] ++ AgentWorker.error_fields(nil, nil)
                )
              )
          end
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
      from w in AgentWorker,
        where: w.agent_uid in ^agent_uids,
        select: {w.agent_uid, w.provider_id}
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

    %{
      provider_id: provider.provider_id,
      kind: provider.kind,
      display_name: provider.display_name,
      config: provider.config,
      is_default: provider.is_default,
      agent_count: agent_count,
      credentials: Map.new(provider.credentials, fn {name, _ciphertext} -> {name, "********"} end)
    }
  end

  def list_projections do
    counts =
      Repo.across_tenants(fn ->
        Repo.all(
          from w in AgentWorker,
            group_by: w.provider_id,
            select: {w.provider_id, count(w.agent_uid)}
        )
      end)
      |> Map.new()

    Enum.map(list(), &projection(&1, Map.get(counts, &1.provider_id, 0)))
  end

  defp changeset(provider, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)
    changeset = Provider.changeset(provider, Map.drop(attrs, ["credentials"]))

    with [] <- Map.keys(attrs) -- @write_keys,
         true <- changeset.valid?,
         row = Ecto.Changeset.apply_changes(changeset),
         {:ok, kind} <- ProviderKind.fetch(row.kind),
         definition = kind.definition(),
         {:ok, settings} <- Configuration.parse(definition.schema, row.config),
         :ok <- immutable_config(provider, definition.schema, settings),
         {:ok, credentials, secrets} <-
           Credentials.prepare(provider, kind, definition, attrs["credentials"] || %{}),
         :ok <- Credentials.validate(kind, definition, settings, secrets) do
      {:ok, Ecto.Changeset.put_change(changeset, :credentials, credentials)}
    else
      false -> {:error, changeset}
      unknown when is_list(unknown) -> {:error, {:unknown_worker_provider_fields, unknown}}
      error -> error
    end
  end

  defp immutable_config(%{__meta__: %{state: :built}}, _schema, _settings), do: :ok

  defp immutable_config(provider, schema, settings) do
    with {:ok, before, _locations} <-
           Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.YAML.parse(provider.config),
         before = Configuration.defaults(schema, before),
         do: Configuration.unchanged_location(schema, before, settings)
  end

  defp set_default_in_tx(repo, changeset) do
    if Ecto.Changeset.get_field(changeset, :is_default) do
      repo.update_all(from(p in Provider, where: p.is_default and p.id != ^changeset.data.id),
        set: [is_default: false]
      )
    end
  end

  # All creates exclude seed import. Only default changes need to exclude
  # each other; independent non-default creates can hold the shared lock.
  @doc false
  def lock_registry(repo, :exclusive),
    do: repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('worker_providers', 0))")

  def lock_registry(repo, :shared),
    do:
      repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended('worker_providers', 0))")
end
