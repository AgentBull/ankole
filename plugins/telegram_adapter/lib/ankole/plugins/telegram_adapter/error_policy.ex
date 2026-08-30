defmodule Ankole.Plugins.TelegramAdapter.ErrorPolicy do
  @moduledoc false

  alias Ankole.Plugins.TelegramAdapter.Client

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Client.Error{} = error}) do
    {:error, {:reply_delivery, action(error), detail(error)}}
  end

  def normalize_delivery_result({:error, reason})
      when reason in [:telegram_partial_delivery, :telegram_send_uncertain] do
    {:error,
     {:reply_delivery, :operator_action_required, %{"code" => "telegram_delivery_unknown"}}}
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

  defp action(%Client.Error{error_code: 429}), do: :retryable
  defp action(%Client.Error{kind: :transport}), do: :retryable

  defp action(%Client.Error{error_code: code}) when code in [401, 403],
    do: :operator_action_required

  defp action(%Client.Error{error_code: code}) when is_integer(code) and code >= 500,
    do: :retryable

  defp action(%Client.Error{error_code: 400}), do: :permanent
  defp action(%Client.Error{}), do: :operator_action_required

  defp detail(error) do
    %{
      "code" => "telegram_api_error",
      "error_code" => error.error_code,
      "description" => error.description,
      "retry_after_seconds" => error.retry_after
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
