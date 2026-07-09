defmodule Ankole.Plugins.LarkAdapter.Jobs.RefreshIMGroup do
  @moduledoc """
  Durable refresh for one Lark IM group observed by a chat binding.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:agent_uid, :binding_name, :chat_id], period: 300]

  alias Ankole.Plugins.LarkAdapter.IMGroups

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def perform(%Oban.Job{
        args: %{
          "agent_uid" => agent_uid,
          "binding_name" => binding_name,
          "chat_id" => chat_id
        }
      })
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(chat_id) do
    IMGroups.refresh_chat(agent_uid, binding_name, chat_id)
  end

  def perform(%Oban.Job{}), do: {:error, :missing_lark_im_refresh_binding}
end
