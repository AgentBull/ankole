defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers do
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

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute

  # A request keeps the Worker wanted this long. Environment calls renew it;
  # active slots and running Jobs also prevent idle release.
  @wanted_for_seconds 300
  @connect_states ~w(starting stale ready)

  def list, do: Repo.all(from worker in AgentWorker, order_by: [asc: worker.agent_uid])

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
         %AgentWorker{state: "ready"} = worker <- lock_in_tx(repo, agent_uid) || :unavailable,
         slots when slots > 0 <- AgentWorker.available_slots(worker) do
      worker
      |> Ecto.Changeset.change(
        capacity: Map.put(worker.capacity, "available_slots", slots - 1),
        load: Map.update(worker.load, "active_slots", 1, &(&1 + 1))
      )
      |> repo.update()
    else
      {:error, _reason} = error -> error
      0 -> {:error, :no_worker_capacity}
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
    |> repo.one()
  end

  @doc "Returns the Agent's Worker when it is ready."
  @spec ready_worker(String.t()) :: {:ok, AgentWorker.t()} | {:error, :agent_worker_unavailable}
  def ready_worker(agent_uid) when is_binary(agent_uid) do
    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{state: "ready"} = worker -> {:ok, worker}
      _worker -> {:error, :agent_worker_unavailable}
    end
  end

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

      is_nil(worker) or worker.state == "deleting" ->
        {:error, :agent_worker_unavailable}

      agent_active(Repo, agent_uid) != :ok ->
        {:error, :agent_not_active}

      is_nil(worker.provider_id) ->
        {:error, :worker_provider_missing}

      worker.state == "absent" and worker.last_error_kind == "rejected" ->
        {:error, {:rejected, worker.last_error}}

      worker.state == "paused" ->
        {:wait, :resuming}

      worker.state == "draining" ->
        {:wait, :replacing}

      worker.state == "absent" and worker.last_error_kind == "pending" ->
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

  Only paths that need a Worker call it: an environment tool, a Codex Job,
  or an Automation Job run. A disabled Agent never
  gets a running Worker, whatever it requests.
  """
  @spec request(String.t()) :: :ok
  def request(agent_uid) when is_binary(agent_uid) do
    {count, _rows} =
      AgentWorker
      |> where([worker], worker.agent_uid == ^agent_uid and worker.state != "deleting")
      |> update([worker],
        set: [
          wanted_until:
            fragment(
              "greatest(coalesce(?, now()), now() + make_interval(secs => ?))",
              worker.wanted_until,
              ^@wanted_for_seconds
            )
        ]
      )
      |> Repo.update_all([])

    if count > 0, do: ReconcileJob.enqueue(agent_uid)
    :ok
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
           from worker in AgentWorker,
             where: worker.agent_uid == ^agent_uid,
             select: {worker.state, worker.token_digest, worker.generation, worker.tenant_id}
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

  @doc "Inserts the absent Worker row in a new Agent's creation transaction."
  @spec insert_in_tx(module(), String.t(), String.t()) :: :ok
  def insert_in_tx(repo, agent_uid, provider_id)
      when is_binary(agent_uid) and is_binary(provider_id) do
    {1, _rows} =
      repo.insert_all(
        AgentWorker,
        [%{tenant_id: Repo.tenant_id!(), agent_uid: agent_uid, provider_id: provider_id}]
      )

    :ok
  end

  @doc """
  Marks the Worker of a deleted Agent for deletion, in the Agent's deletion
  transaction. The credential stops working at once; `ReconcileJob` deletes
  the backend objects and then the row.
  """
  @spec mark_deleting_in_tx(module(), String.t()) :: :ok
  def mark_deleting_in_tx(repo, agent_uid) when is_binary(agent_uid) do
    AgentWorker
    |> where([worker], worker.agent_uid == ^agent_uid)
    |> update([worker],
      set: [
        state: "deleting",
        incarnation_id: nil,
        transport_route: nil,
        wanted_until: nil,
        state_changed_at: fragment("now()")
      ]
    )
    |> repo.update_all([])

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
           from principal in Principal,
             where: principal.uid == ^agent_uid and principal.type == :agent,
             select: principal.status
         ) do
      :active -> :ok
      _status -> {:error, :agent_not_active}
    end
  end
end
