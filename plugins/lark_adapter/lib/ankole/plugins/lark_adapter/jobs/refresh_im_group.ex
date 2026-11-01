defmodule Ankole.Plugins.LarkAdapter.Jobs.RefreshIMGroup do
  @moduledoc """
  Durable refresh for one Lark IM group observed by a chat binding.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:binding_id, :chat_id], period: 300]

  alias Ankole.Plugins.LarkAdapter.IMGroups

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def run(%Oban.Job{
        args: %{
          "binding_id" => binding_id,
          "chat_id" => chat_id
        }
      })
      when is_binary(binding_id) and is_binary(chat_id) do
    IMGroups.refresh_chat(binding_id, chat_id)
  end

  def run(%Oban.Job{}), do: {:error, :missing_lark_im_refresh_binding}
end
