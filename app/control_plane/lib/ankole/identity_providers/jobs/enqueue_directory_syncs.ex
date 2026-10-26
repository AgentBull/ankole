defmodule Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs do
  @moduledoc """
  Periodic enqueue edge for identity-provider full directory syncs.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  alias Ankole.IdentityProviders.DirectorySync

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def run(%Oban.Job{}),
    do: DirectorySync.enqueue_site_directory_syncs(reason: "periodic", source: "cron")
end
