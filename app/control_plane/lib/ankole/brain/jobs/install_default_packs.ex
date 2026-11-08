defmodule Ankole.Brain.Jobs.InstallDefaultPacks do
  @moduledoc """
  Installs the default schema packs in a workspace that predates one of them.

  The migration that ships a new default pack queues this job once per
  workspace. Installation keeps the packs already installed and converges
  when every default pack is present.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:tenant_id],
      period: :infinity,
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  @impl Ankole.Job
  def run(_job) do
    case Ankole.Brain.SchemaPacks.install_packs([]) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
