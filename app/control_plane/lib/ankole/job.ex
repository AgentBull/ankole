defmodule Ankole.Job do
  @moduledoc "Sets the tenant context at the durable job boundary."

  @callback run(Oban.Job.t()) :: term()

  defmacro __using__(opts) do
    {tenancy, worker_opts} = Keyword.pop!(opts, :tenancy)

    unless tenancy in [:tenant, :site] do
      raise ArgumentError, "Ankole.Job requires tenancy: :tenant or :site"
    end

    quote do
      use Oban.Worker, unquote(worker_opts)
      @behaviour Ankole.Job

      def __tenancy__, do: unquote(tenancy)

      @impl Oban.Worker
      def new(args, opts) do
        super(Ankole.Job.arguments(unquote(tenancy), args), opts)
      end

      @impl Oban.Worker
      def perform(job), do: Ankole.Job.perform(unquote(tenancy), job, &run/1)
    end
  end

  @doc """
  Moves the one pending wakeup of `worker` for `args` to `due_at`.

  The worker's unique keys select the wakeup. A wakeup that is available,
  scheduled or retryable moves to the new time. An executing wakeup keeps its
  claim, so the insert gives the next wakeup its own row.
  """
  @spec schedule_in_tx(module(), module(), map(), DateTime.t()) :: :ok | {:error, term()}
  def schedule_in_tx(repo, worker, args, due_at) do
    import Ecto.Query, only: [from: 2]

    with {:ok, job} <- Oban.insert(worker.new(args, scheduled_at: due_at)) do
      state =
        if DateTime.after?(due_at, DateTime.utc_now(:microsecond)),
          do: "scheduled",
          else: "available"

      repo.update_all(
        from(job in Oban.Job,
          where: job.id == ^job.id and job.state in ["available", "scheduled", "retryable"]
        ),
        set: [scheduled_at: due_at, state: state]
      )

      :ok
    end
  end

  @doc false
  def arguments(:site, args), do: args

  def arguments(:tenant, args) when is_map(args) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    tenant_id = Map.get(args, "tenant_id") || Ankole.Repo.tenant_id!()
    {:ok, tenant_id} = Ecto.UUID.cast(tenant_id)
    Map.put(args, "tenant_id", tenant_id)
  end

  @doc false
  def perform(:site, job, run), do: Ankole.Repo.without_tenant(fn -> run.(job) end)

  def perform(:tenant, %Oban.Job{args: %{"tenant_id" => tenant_id}} = job, run) do
    Ankole.Repo.with_tenant(tenant_id, fn ->
      case Ankole.Repo.get(Ankole.Tenants.Tenant, tenant_id) do
        nil -> {:cancel, :tenant_deleted}
        _tenant -> run.(job)
      end
    end)
  end
end
