defmodule Ankole.AgentWorkers do
  @moduledoc """
  The one Worker of each Agent: placement, lookups, credentials, and requests.

  Every Agent has one `agent_workers` row (`Schemas.AgentWorker`). This module
  decides whether that Agent may reserve an execution slot, which connection reaches its
  Worker, and which credential may connect as that Worker. The lifecycle work
  (creating, starting, stopping, replacing, and deleting Workers) runs in
  `AgentWorkers.ReconcileJob`; a caller that needs a Worker calls `request/1`
  and never waits for the Worker to start.

  Conversation inputs do not record a Worker or a route. A send reads
  the Agent's row at send time (`target/1`), so a reconnected Worker is reached
  on its new connection.
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerRoute

  defdelegate admit_join(join_payload, auth), to: Ankole.AgentWorkers.WorkerAdmission

  defdelegate handle_worker_heartbeat(worker_heartbeat, auth),
    to: Ankole.AgentWorkers.WorkerAdmission

  # A request keeps the Worker wanted this long. Environment calls renew it;
  # active slots and running Jobs also prevent idle release.
  @connect_states [:starting, :stale, :ready]

  def list, do: Repo.all(from(worker in AgentWorker, order_by: [asc: worker.agent_uid]))

  @doc """
  Reads provider inventory before the current Worker rows used to identify it.

  Creation commits the Worker before it creates a platform instance. The full
  inventory must finish first, so a concurrent create cannot look like an orphan.
  The platform callback stays outside the cross-tenant query scope.
  """
  def inventory_with_workers(provider_id, uid_or_all, inventory) when is_function(inventory, 0) do
    with {:ok, objects} <- inventory.() do
      query = from(worker in AgentWorker, where: worker.provider_id == ^provider_id)

      rows =
        if uid_or_all == :all,
          do: Repo.across_tenants(fn -> Repo.all(query) end),
          else: Repo.all(from(worker in query, where: worker.agent_uid == ^uid_or_all))

      {:ok, objects, rows}
    end
  end

  def topic(agent_uid), do: "agent_worker:#{agent_uid}"

  def notify_changed(agent_uid) do
    Phoenix.PubSub.broadcast(Ankole.PubSub, topic(agent_uid), {:worker_changed, agent_uid})
  end

  @doc """
  Locks the Agent's row and takes one environment or Codex slot.

  Placement looks only at this row. It locks the row with a plain
  `FOR UPDATE`: with one candidate, `SKIP LOCKED` would make a concurrent
  placement for the same Agent see no Worker. Failures:

    * `:agent_not_active` when the Agent is disabled;
    * `:agent_worker_unavailable` when its Worker is not ready;
    * `:no_worker_capacity` when its ready Worker has no free slot.
  """
  @spec reserve_slot_in_tx(module(), String.t()) ::
          {:ok, AgentWorker.t()}
          | {:error, :agent_not_active | :agent_worker_unavailable | :no_worker_capacity}
  def reserve_slot_in_tx(repo, agent_uid) when is_binary(agent_uid) do
    with :ok <- agent_active(repo, agent_uid),
         worker = lock_in_tx(repo, agent_uid),
         true <- ready?(worker) do
      if AgentWorker.available_slots(worker) > 0,
        do: Ankole.Ash.update(worker, :reserve_slot, %{}),
        else: {:error, :no_worker_capacity}
    else
      {:error, _reason} = error -> error
      _not_ready -> {:error, :agent_worker_unavailable}
    end
  end

  @doc """
  Locks the Agent's row inside the caller's transaction.

  Codex attempt admission locks this row before the Agent's Job slots.
  """
  @spec lock_in_tx(module(), String.t()) :: AgentWorker.t() | nil
  def lock_in_tx(repo, agent_uid) when is_binary(agent_uid) do
    AgentWorker
    |> where([worker], worker.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one(lock_identity: {"agent_workers", agent_uid})
  end

  @doc "Returns the Agent's Worker when it is ready."
  @spec ready_worker(String.t()) :: {:ok, AgentWorker.t()} | {:error, :agent_worker_unavailable}
  def ready_worker(agent_uid) when is_binary(agent_uid) do
    worker = Repo.get(AgentWorker, agent_uid)
    if ready?(worker), do: {:ok, worker}, else: {:error, :agent_worker_unavailable}
  end

  @doc """
  Decides the readiness wait for a new attempt from the caller's current facts.

  Returns the decision and the wait start to persist. A ready Worker clears the
  clock even when work capacity is full. Full work capacity does not start or
  reset a clock, and does not report a timeout. Otherwise an unavailable Worker
  starts or continues the clock. Retries keep the stored start.

  This function does not read storage, reserve slots, or schedule a wakeup.
  The caller owns work capacity, persistence, and the result of a timeout.
  """
  @spec wait_status(
          AgentWorker.t() | nil,
          boolean(),
          DateTime.t() | nil,
          DateTime.t(),
          pos_integer()
        ) ::
          {:ready | :wait | :timed_out, DateTime.t() | nil}
  def wait_status(worker, capacity_available?, started_at, now, ready_timeout_ms) do
    cond do
      ready?(worker) ->
        {:ready, nil}

      not capacity_available? ->
        {:wait, started_at}

      is_nil(started_at) ->
        {:wait, now}

      DateTime.diff(now, started_at, :millisecond) >= ready_timeout_ms ->
        {:timed_out, started_at}

      true ->
        {:wait, started_at}
    end
  end

  defp ready?(%AgentWorker{state: :ready}), do: true
  defp ready?(_worker), do: false

  @doc """
  Returns the Agent's Worker while it has a connection that can carry Turn
  traffic: ready, or draining while its accepted Turns finish.
  """
  @spec connected_worker(String.t()) ::
          {:ok, AgentWorker.t()} | {:error, :agent_worker_unavailable}
  def connected_worker(agent_uid) when is_binary(agent_uid) do
    with %AgentWorker{} = worker <- Repo.get(AgentWorker, agent_uid),
         true <- AgentWorker.connected?(worker) do
      {:ok, worker}
    else
      _worker -> {:error, :agent_worker_unavailable}
    end
  end

  @doc "Returns workspace readiness, its acquisition phase, or a definite failure."
  @spec workspace_status(String.t()) ::
          {:ok, AgentWorker.t()}
          | {:wait, :starting | :resuming | :preparing | :retrying | :replacing}
          | {:error,
             :agent_not_active
             | :worker_provider_missing
             | :agent_worker_unavailable
             | {:rejected, String.t()}}
  def workspace_status(agent_uid) do
    worker = Repo.get(AgentWorker, agent_uid)

    cond do
      worker && AgentWorker.connected?(worker) ->
        {:ok, worker}

      is_nil(worker) or worker.state == :deleting ->
        {:error, :agent_worker_unavailable}

      agent_active(Repo, agent_uid) != :ok ->
        {:error, :agent_not_active}

      is_nil(worker.provider_id) ->
        {:error, :worker_provider_missing}

      worker.state == :absent and worker.last_error_kind == "rejected" ->
        {:error, {:rejected, worker.last_error}}

      worker.state == :paused ->
        {:wait, :resuming}

      worker.state == :draining ->
        {:wait, :replacing}

      worker.state == :absent and worker.last_error_kind == "pending" ->
        {:wait, :preparing}

      worker.last_error_kind == "transient" ->
        {:wait, :retrying}

      true ->
        {:wait, :starting}
    end
  end

  @doc "The `WorkerRoute` target of the row's current connection."
  @spec target(AgentWorker.t()) :: WorkerRoute.target()
  def target(%AgentWorker{agent_uid: agent_uid, transport_route: route}),
    do: %{worker_id: agent_uid, transport_route: route}

  @doc """
  Records that a path needs the Agent's Worker now, and schedules
  reconciliation. It does not wait for the Worker.

  Environment tools, Codex Jobs, and Automation runs call it after the
  initial startup request. A disabled Agent never
  gets a running Worker, whatever it requests.
  """
  @spec request(String.t()) :: :ok
  def request(agent_uid) when is_binary(agent_uid) do
    result =
      AgentWorker
      |> Ash.Query.filter(agent_uid == ^agent_uid)
      |> Ash.Query.select([:agent_uid])
      |> Ankole.Ash.bulk_update(:request, %{},
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: []} -> :ok
      %Ash.BulkResult{status: :success} -> ReconcileJob.enqueue(agent_uid)
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end

  @doc """
  Checks the credential of a connecting Worker and returns its generation and tenant.

  The credential is the random token of the Agent's current generation. Only
  its SHA-256 digest is used for admission. An encrypted copy permits create
  retries after a crash. Only a row that is starting, stale, or ready accepts
  a connection: a paused, draining, or deleted Worker, and a
  token of a former generation, cannot connect.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, %{generation: String.t(), tenant_id: String.t()}} | {:error, atom()}
  def authenticate(agent_uid, token)
      when is_binary(agent_uid) and is_binary(token) and token != "" do
    digest = :crypto.hash(:sha256, token)

    case Repo.one(
           from(worker in AgentWorker,
             where: worker.agent_uid == ^agent_uid,
             select: {worker.state, worker.token_digest, worker.generation, worker.tenant_id}
           )
         ) do
      {state, stored, generation, tenant_id}
      when state in @connect_states and is_binary(stored) ->
        if Plug.Crypto.secure_compare(digest, stored),
          do: {:ok, %{generation: generation, tenant_id: tenant_id}},
          else: {:error, :invalid_worker_credential}

      {_state, _stored, _generation, _tenant_id} ->
        {:error, :stale_worker_generation}

      nil ->
        {:error, :unknown_worker}
    end
  end

  def authenticate(_agent_uid, _token), do: {:error, :invalid_worker_credential}

  @doc "Issues a credential that can be sent again after a coordinator crash."
  def issue_credential(agent_uid, generation) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, ciphertext} <-
           Ankole.SecretKeyBase.seal(token, "agent_worker_credential", [agent_uid, generation]) do
      {:ok, %{token_digest: :crypto.hash(:sha256, token), token_ciphertext: ciphertext}}
    end
  end

  @doc "Restores the credential of this generation for an idempotent create."
  def credential(%AgentWorker{} = worker),
    do:
      Ankole.SecretKeyBase.unseal(worker.token_ciphertext, "agent_worker_credential", [
        worker.agent_uid,
        worker.generation
      ])

  @doc "Records and enqueues initial Worker startup in the Agent's creation transaction."
  @spec insert_in_tx(module(), String.t(), String.t()) :: :ok
  def insert_in_tx(repo, agent_uid, provider_id)
      when is_binary(agent_uid) and is_binary(provider_id) do
    case Ankole.Ash.create(AgentWorker, :register, %{
           agent_uid: agent_uid,
           provider_id: provider_id
         }) do
      {:ok, _worker} ->
        %{agent_uid: agent_uid} |> ReconcileJob.new() |> Oban.insert!()
        :ok

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  @doc """
  Marks the Worker of a deleted Agent for deletion, in the Agent's deletion
  transaction. The credential stops working at once; `ReconcileJob` deletes
  the backend objects and then the row.
  """
  @spec mark_deleting_in_tx(module(), String.t()) :: :ok
  def mark_deleting_in_tx(repo, agent_uid) when is_binary(agent_uid) do
    case AgentWorker
         |> Ash.Query.filter(agent_uid == ^agent_uid)
         |> Ankole.Ash.bulk_update(:mark_deleting, %{}, strategy: [:atomic], return_errors?: true) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> repo.rollback(Ash.Error.to_error_class(errors))
    end
  end

  @doc "Clears rejected launch diagnostics after the site provider changes."
  def clear_provider_rejections_in_tx(provider_id) do
    tenants =
      Repo.across_tenants(fn ->
        Repo.all(
          from(worker in AgentWorker,
            where: worker.provider_id == ^provider_id,
            where: worker.last_error_kind == "rejected",
            distinct: worker.tenant_id,
            select: worker.tenant_id
          )
        )
      end)

    Enum.each(tenants, fn tenant ->
      Repo.with_tenant(tenant, fn ->
        case AgentWorker
             |> Ash.Query.filter(provider_id == ^provider_id)
             |> Ankole.Ash.bulk_update(:clear_rejection, %{},
               strategy: [:atomic],
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success} -> :ok
          %Ash.BulkResult{errors: errors} -> Repo.rollback(Ash.Error.to_error_class(errors))
        end
      end)
    end)

    :ok
  end

  @doc "Assigns legacy unbound Workers inside the bootstrap registry transaction."
  def assign_legacy_provider_in_tx(provider_id) do
    workers =
      Repo.across_tenants(fn ->
        AgentWorker
        |> where([worker], is_nil(worker.provider_id) and worker.state != :deleting)
        |> order_by([worker], worker.agent_uid)
        |> lock("FOR UPDATE")
        |> Repo.lock_all("agent_workers", :agent_uid)
      end)

    Enum.each(workers, fn worker ->
      Repo.with_tenant(worker.tenant_id, fn ->
        case Ankole.Ash.update(worker, :assign_provider, %{provider_id: provider_id}) do
          {:ok, _updated} -> :ok
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end)

    :ok
  end

  @doc """
  Schedules reconciliation after a change outside this module, for example
  an Agent that was disabled or deleted. A lost insert is found by
  `SweepJob`.
  """
  @spec reconcile(String.t()) :: :ok
  def reconcile(agent_uid) when is_binary(agent_uid), do: ReconcileJob.enqueue(agent_uid)

  @doc """
  Whether the default Worker provider accepts requests.
  """
  @spec provider_status() :: :ok | {:error, term()}
  def provider_status, do: Providers.default_status()

  defp agent_active(repo, agent_uid) do
    case repo.one(
           from(principal in Principal,
             where: principal.uid == ^agent_uid and principal.type == :agent,
             select: principal.status
           )
         ) do
      :active -> :ok
      _status -> {:error, :agent_not_active}
    end
  end
end
