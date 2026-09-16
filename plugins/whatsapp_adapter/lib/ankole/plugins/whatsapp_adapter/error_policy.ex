defmodule Ankole.Plugins.WhatsAppAdapter.ErrorPolicy do
  @moduledoc false

  alias Ankole.Plugins.WhatsAppAdapter.Client

  # 190 is an expired or revoked access token, and 131048 restricts the phone
  # number after a quality or spam signal. Only an operator can issue a new
  # token or repair the quality rating.
  @operator_codes [190, 131_048]

  # 130429 is the cloud API throughput limit and 131056 the per-pair limit.
  # 131000 is the generic failure that Meta itself asks the caller to repeat,
  # and 131016 says the service is unavailable. All of them clear without any
  # change to the binding.
  @retryable_codes [130_429, 131_056, 131_000, 131_016]

  # 131047 closes the customer service window, 131026 means the number cannot
  # receive the message, 131051 rejects an unsupported message type, 131053
  # rejects the uploaded media, and 133010 means the number is not registered.
  # None of them can succeed on a repeat of the same request.
  @permanent_codes [131_047, 131_026, 131_051, 131_053, 133_010]

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Client.Error{} = error}) do
    {:error, {:reply_delivery, action(error), detail(error)}}
  end

  def normalize_delivery_result({:error, :customer_service_window_closed}) do
    {:error, {:reply_delivery, :permanent, %{"code" => "customer_service_window_closed"}}}
  end

  def normalize_delivery_result({:error, :outbound_attachment_unsupported}) do
    {:error, {:reply_delivery, :permanent, %{"code" => "outbound_attachment_unsupported"}}}
  end

  def normalize_delivery_result({:error, :binding_phone_number_mismatch}) do
    {:error,
     {:reply_delivery, :operator_action_required, %{"code" => "binding_phone_number_mismatch"}}}
  end

  def normalize_delivery_result({:error, :outbound_attachment_path_missing}) do
    {:error, {:reply_delivery, :operator_action_required, %{"code" => "attachment_path_missing"}}}
  end

  def normalize_delivery_result(result), do: result

  defp action(%Client.Error{kind: :transport}), do: :retryable

  defp action(%Client.Error{code: code}) when code in @operator_codes,
    do: :operator_action_required

  defp action(%Client.Error{code: code}) when code in @permanent_codes, do: :permanent
  defp action(%Client.Error{code: code}) when code in @retryable_codes, do: :retryable

  defp action(%Client.Error{status: status}) when status in [401, 403],
    do: :operator_action_required

  defp action(%Client.Error{status: 429}), do: :retryable

  defp action(%Client.Error{status: status}) when is_integer(status) and status >= 500,
    do: :retryable

  defp action(%Client.Error{}), do: :permanent

  defp detail(error) do
    %{
      "code" => error.code || "whatsapp_api_error",
      "status" => error.status,
      "message" => error.message
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
