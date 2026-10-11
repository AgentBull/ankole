defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.PrepareImageJobTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{PrepareImageJob, Providers}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Provider

  setup do
    row = worker_provider_fixture()
    {:ok, provider} = Providers.load(row)
    %{provider: provider, api: Ankole.AgentWorkerDockerHTTP.install()}
  end

  test "image work is site scoped and unique even during execution", %{provider: provider} do
    assert PrepareImageJob.__tenancy__() == :site
    assert :executing in PrepareImageJob.__opts__()[:unique][:states]
    assert :ok = PrepareImageJob.enqueue(provider)
    [job] = all_enqueued(worker: PrepareImageJob)
    refute Map.has_key?(job.args, "tenant_id")
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])
    assert :ok = PrepareImageJob.enqueue(provider)
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 1

    changed = %{provider | runtime: %{provider.runtime | image: "worker:next"}}
    assert :ok = PrepareImageJob.enqueue(changed)
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 2
    changed = %{changed | settings_digest: "next-settings"}
    assert :ok = PrepareImageJob.enqueue(changed)
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 3
  end

  test "prepares an image without starting an Agent instance", %{provider: provider, api: api} do
    assert :ok = perform_job(PrepareImageJob, %{provider_id: provider.provider_id})
    assert Agent.get(api, & &1.containers) == %{}
    assert [{"GET", "/images/" <> _}] = Agent.get(api, & &1.calls)
  end

  test "invalid provider configuration returns an error for Oban retry", %{provider: provider} do
    Repo.update_all(from(p in Provider, where: p.provider_id == ^provider.provider_id),
      set: [config: "unknown: true\n"]
    )

    assert {:error, {:invalid_worker_provider_config, _}} =
             perform_job(PrepareImageJob, %{provider_id: provider.provider_id})
  end
end
