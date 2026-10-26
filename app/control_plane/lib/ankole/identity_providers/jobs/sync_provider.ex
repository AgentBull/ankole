defmodule Ankole.IdentityProviders.Jobs.SyncProvider do
  @moduledoc """
  Durable full-directory sync for identity-provider adapters.
  """

  use Ankole.Job, tenancy: :tenant, queue: :default, max_attempts: 3

  alias Ankole.IdentityProviders.DirectorySync

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()}
  def run(%Oban.Job{args: %{"provider_id" => provider_id}}) when is_binary(provider_id) do
    case DirectorySync.sync_provider(provider_id) do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
    end
  end
end
