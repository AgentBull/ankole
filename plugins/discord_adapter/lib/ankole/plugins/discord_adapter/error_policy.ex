defmodule Ankole.Plugins.DiscordAdapter.ErrorPolicy do
  @moduledoc false

  alias Ankole.Plugins.DiscordAdapter.Client

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Client.Error{} = error}) do
    {:error, {:reply_delivery, action(error), detail(error)}}
  end

  def normalize_delivery_result({:error, reason})
      when reason in [:discord_partial_delivery, :discord_send_uncertain] do
    {:error, {:reply_delivery, :operator_action_required, %{"code" => "discord_delivery_unknown"}}}
  end

  def normalize_delivery_result({:error, :outbound_attachment_path_missing}) do
    {:error, {:reply_delivery, :operator_action_required, %{"code" => "attachment_path_missing"}}}
  end

  def normalize_delivery_result({:error, %{"code" => code}}) when is_binary(code) do
    {:error,
     {:reply_delivery, :operator_action_required,
      %{"code" => "attachment_file_unavailable", "worker_file_code" => code}}}
  end

  def normalize_delivery_result(result), do: result

  defp action(%Client.Error{status: 429}), do: :retryable
  defp action(%Client.Error{kind: :transport}), do: :retryable

  defp action(%Client.Error{status: status}) when status in [401, 403], do: :operator_action_required

  defp action(%Client.Error{status: status}) when is_integer(status) and status >= 500,
    do: :retryable

  defp action(%Client.Error{status: status}) when status in [400, 404], do: :permanent
  defp action(%Client.Error{}), do: :operator_action_required

  defp detail(error) do
    %{
      "code" => "discord_api_error",
      "status" => error.status,
      "discord_code" => error.code,
      "message" => error.message,
      "retry_after_seconds" => error.retry_after
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
