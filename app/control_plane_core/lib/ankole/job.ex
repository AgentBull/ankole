defmodule Ankole.Job do
  @moduledoc """
  Sets the tenant context at the durable job boundary.

  A worker module depends on this module at compile time (`use Ankole.Job`).
  This module calls only the Repo and Oban, so a change to a domain does not
  recompile the workers. `Ankole.Job.Context` runs each job.
  """

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
      def perform(job), do: Ankole.Job.Context.perform(unquote(tenancy), job, &run/1)
    end
  end

  @doc """
  Moves the one pending wakeup of `worker` for `args` to `due_at`.

  The worker's unique keys select the wakeup. A wakeup that is available,
  scheduled or retryable moves to the new time. An executing wakeup keeps its
  claim, so the insert gives the next wakeup its own row. With
  `only_earlier: true`, a pending wakeup moves only to an earlier time, so a
  later request cannot postpone a committed wakeup.
  """
  @spec schedule_in_tx(module(), module(), map(), DateTime.t(), keyword()) ::
          :ok | {:error, term()}
  def schedule_in_tx(repo, worker, args, due_at, opts \\ []) do
    import Ecto.Query, only: [from: 2, where: 3]

    state =
      if DateTime.after?(due_at, DateTime.utc_now(:microsecond)),
        do: "scheduled",
        else: "available"

    with {:ok, job} <- Oban.insert(worker.new(args, scheduled_at: due_at, state: state)) do
      # A new row already has its time and state, so only an existing pending
      # wakeup moves. An inline test engine runs the job without a row.
      if job.id && job.conflict? do
        query =
          from(job in Oban.Job,
            where: job.id == ^job.id and job.state in ["available", "scheduled", "retryable"]
          )

        query =
          if Keyword.get(opts, :only_earlier, false),
            do: where(query, [job], job.scheduled_at > ^due_at),
            else: query

        repo.update_all(query, set: [scheduled_at: due_at, state: state])
      end

      :ok
    end
  end

  @doc "Moves the pending wakeup of `worker` in its own transaction. See `schedule_in_tx/5`."
  @spec schedule(module(), map(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def schedule(worker, args, due_at, opts \\ []) do
    with {:ok, :ok} <-
           Ankole.Repo.transact(fn repo ->
             with :ok <- schedule_in_tx(repo, worker, args, due_at, opts), do: {:ok, :ok}
           end),
         do: :ok
  end

  @doc false
  def arguments(:site, args), do: args

  def arguments(:tenant, args) when is_map(args) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    tenant_id = Map.get(args, "tenant_id") || Ankole.Repo.tenant_id!()
    {:ok, tenant_id} = Ecto.UUID.cast(tenant_id)
    Map.put(args, "tenant_id", tenant_id)
  end
end
