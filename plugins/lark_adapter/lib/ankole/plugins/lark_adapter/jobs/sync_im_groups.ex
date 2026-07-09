defmodule Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups do
  @moduledoc """
  Durable full IM group sync for one enabled Lark chat binding.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:agent_uid, :binding_name], period: 300]

  alias Ankole.Plugins.LarkAdapter.IMGroups

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def perform(%Oban.Job{args: %{"agent_uid" => agent_uid, "binding_name" => binding_name}})
      when is_binary(agent_uid) and is_binary(binding_name) do
    IMGroups.sync_binding(agent_uid, binding_name)
  end

  def perform(%Oban.Job{}), do: {:error, :missing_lark_im_sync_binding}
end
