defmodule Ankole.WorkerStorageFixtures do
  @moduledoc """
  Shared steps of the cloud Worker storage checks.

  Each check creates two providers of one kind with one Agent on each, then
  drives reconciliation directly while it waits for a Worker state.
  """

  import ExUnit.Assertions
  import Ecto.Query
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.{Principals, Repo, WorkerFiles}
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.AgentWorker

  @doc "Creates two providers of `kind` and one Agent on each; returns `{uids, provider_ids}`."
  def storage_agents!(kind, suffix, owner_uid, config, credentials) do
    ids = Enum.map(~w(a b), &"#{String.replace(kind, "_", "-")}-check-#{&1}-#{suffix}")

    uids =
      for id <- ids do
        assert {:ok, _} =
                 Providers.create(%{
                   provider_id: id,
                   display_name: "#{kind} storage check",
                   kind: kind,
                   config: config,
                   credentials: credentials
                 })

        %{principal: agent} =
          Ankole.PrincipalsFixtures.agent_fixture(%{
            owner_principal_uid: owner_uid,
            worker_provider_id: id
          })

        agent.uid
      end

    {uids, ids}
  end

  @doc """
  Reconciles until the Agent's Worker reaches `state` (nil means no row) with a
  generation other than `previous`. Waiting for `ready` keeps the demand alive.
  """
  def await_worker_state!(uid, state, previous \\ nil) do
    assert {:ok, result} =
             wait_until(deadline(1_200_000), fn ->
               if state == :ready, do: AgentWorkers.request(uid)

               case ReconcileJob.perform(%Oban.Job{
                      args: Ankole.Job.arguments(:tenant, %{"agent_uid" => uid})
                    }) do
                 :ok -> :ok
                 {:snooze, seconds} -> Process.sleep(seconds * 1_000)
                 {:error, reason} -> IO.puts("Reconciliation will retry: #{inspect(reason)}")
               end

               case Repo.get(AgentWorker, uid) do
                 nil when is_nil(state) ->
                   {:ok, nil}

                 %AgentWorker{state: ^state, generation: generation} = worker
                 when is_nil(previous) or generation != previous ->
                   {:ok, worker}

                 _other ->
                   Process.sleep(1_000)
                   false
               end
             end),
           "Worker did not reach #{inspect(state)}: #{inspect(Repo.get(AgentWorker, uid))}"

    result
  end

  @doc "Writes one proof file to the Worker's Home."
  def put_proof!(worker, content, path \\ "proof.txt") do
    source = Path.join(System.tmp_dir!(), "#{worker.agent_uid}-storage-proof")
    File.write!(source, content)

    try do
      assert {:ok, %{"size" => size}} = WorkerFiles.put(path, {:file, source}, worker: worker)
      assert size == byte_size(content)
    after
      File.rm!(source)
    end
  end

  @doc "Reads the proof file back from the Worker's Home."
  def assert_proof!(worker, expected) do
    assert {:ok, %{"body" => body}} = WorkerFiles.stream("proof.txt", worker: worker)
    assert Enum.join(body) == expected
  end

  @doc """
  Deletes the Workers, Agents, owner and providers. A Worker whose platform
  cleanup fails keeps its row, which recovery still needs.
  """
  def cleanup_storage!(uids, provider_ids, owner_uid) do
    for uid <- uids, Repo.get(AgentWorker, uid) do
      assert {:ok, :ok} =
               Repo.transact(fn repo ->
                 :ok = AgentWorkers.mark_deleting_in_tx(repo, uid)
                 {:ok, :ok}
               end)

      assert await_worker_state!(uid, nil) == nil
    end

    slugs = ["people/#{owner_uid}" | Enum.map(uids, &"agents/#{&1}")]
    Repo.delete_all(from o in Ankole.Brain.Schemas.Object, where: o.slug in ^slugs)
    Repo.delete_all(from p in Principals.Principal, where: p.uid in ^uids)
    Repo.delete_all(from p in Principals.Principal, where: p.uid == ^owner_uid)
    Repo.delete_all(from job in Oban.Job, where: fragment("?->>'agent_uid'", job.args) in ^uids)

    for id <- provider_ids,
        {:ok, _} <- [Providers.fetch(id)],
        do: assert({:ok, _} = Providers.delete(id))
  end
end
