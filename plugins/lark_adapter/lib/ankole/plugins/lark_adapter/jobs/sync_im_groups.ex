defmodule Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups do
  @moduledoc """
  Durable full IM group sync for one enabled Lark chat binding.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:binding_id], period: 300]

  alias Ankole.Plugins.LarkAdapter.IMGroups

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def run(%Oban.Job{args: %{"binding_id" => binding_id}})
      when is_binary(binding_id) do
    IMGroups.sync_binding(binding_id)
  end

  def run(%Oban.Job{}), do: {:error, :missing_lark_im_sync_binding}
end
