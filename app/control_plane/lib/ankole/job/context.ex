defmodule Ankole.Job.Context do
  @moduledoc """
  Runs one durable job in the tenant context that its arguments name.

  A job of a deleted tenant is cancelled.
  """

  @doc false
  def perform(:site, job, run), do: Ankole.Repo.without_tenant(fn -> run.(job) end)

  def perform(:tenant, %Oban.Job{args: %{"tenant_id" => tenant_id}} = job, run) do
    Ankole.Repo.with_tenant(tenant_id, fn ->
      case Ankole.Tenants.get(tenant_id) do
        {:ok, _tenant} -> run.(job)
        {:error, :not_found} -> {:cancel, :tenant_deleted}
      end
    end)
  end
end
