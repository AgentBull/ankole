defmodule Ankole.IdentityProviders.Jobs.SyncProvider do
  @moduledoc """
  Durable full-directory sync for identity-provider adapters.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.IdentityProviders

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}}) when is_binary(provider_id) do
    IdentityProviders.sync_provider(provider_id)
  end
end
