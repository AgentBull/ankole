defmodule Ankole.Plugins.LineAdapter.ErrorPolicy do
  @moduledoc false

  alias Ankole.Plugins.LineAdapter.Client

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Client.Error{} = error}) do
    {:error, {:reply_delivery, action(error), detail(error)}}
  end

  def normalize_delivery_result({:error, :outbound_attachments_not_supported}) do
    {:error, {:reply_delivery, :permanent, %{"code" => "outbound_attachments_not_supported"}}}
  end

  def normalize_delivery_result(result), do: result

  # LINE answers a per-second limit and an exhausted monthly plan with the same
  # 429. Only the plan message names the month, and only an operator can lift
  # that one, by changing the plan or waiting for the next month.
  defp action(%Client.Error{status: 429, message: message}) do
    if monthly_limit?(message), do: :operator_action_required, else: :retryable
  end

  defp action(%Client.Error{kind: :transport}), do: :retryable

  defp action(%Client.Error{status: status}) when status in [401, 403],
    do: :operator_action_required

  defp action(%Client.Error{status: status}) when is_integer(status) and status >= 500,
    do: :retryable

  defp action(%Client.Error{status: status}) when status in [400, 404], do: :permanent
  defp action(%Client.Error{}), do: :operator_action_required

  defp monthly_limit?(message) when is_binary(message),
    do: message |> String.downcase() |> String.contains?("monthly limit")

  defp monthly_limit?(_message), do: false

  defp detail(error) do
    %{
      "code" => "line_api_error",
      "status" => error.status,
      "message" => error.message
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
