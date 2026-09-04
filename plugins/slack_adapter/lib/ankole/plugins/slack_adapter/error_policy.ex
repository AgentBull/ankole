defmodule Ankole.Plugins.SlackAdapter.ErrorPolicy do
  @moduledoc false

  alias SlackOpenAPI.Error

  @retryable_statuses [408, 409, 425, 429]

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Error{} = error}) do
    delivery_error(error_action(error), provider_error(error))
  end

  def normalize_delivery_result({:error, {:rate_limited, seconds}})
      when is_integer(seconds) and seconds >= 0 do
    delivery_error(:retryable, %{
      "code" => "rate_limited",
      "retry_after_seconds" => seconds
    })
  end

  def normalize_delivery_result({:error, :outbound_attachment_path_missing}) do
    delivery_error(:operator_action_required, %{"code" => "attachment_path_missing"})
  end

  def normalize_delivery_result({:error, :multiple_outbound_attachments_not_supported}) do
    delivery_error(:operator_action_required, %{
      "code" => "multiple_attachments_not_supported"
    })
  end

  def normalize_delivery_result({:error, :slack_partial_delivery}) do
    delivery_error(:operator_action_required, %{"code" => "slack_delivery_unknown"})
  end

  def normalize_delivery_result({:error, %{"code" => code}}) when is_binary(code) do
    delivery_error(:operator_action_required, %{
      "code" => "attachment_file_unavailable",
      "worker_file_code" => code
    })
  end

  def normalize_delivery_result(result), do: result

  defp error_action(%Error{} = error) do
    cond do
      Error.retryable?(error) -> :retryable
      error.status in @retryable_statuses -> :retryable
      true -> :operator_action_required
    end
  end

  defp provider_error(%Error{} = error) do
    %{
      "code" => normalize_code(error.reason),
      "http_status" => error.status,
      "needed_scope" => raw_text(error.raw, "needed"),
      "retry_after_seconds" => error.retry_after
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp raw_text(%{} = raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp raw_text(_raw, _key), do: nil

  defp normalize_code(value) when is_binary(value), do: value
  defp normalize_code(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_code(_value), do: "slack_api_error"

  defp delivery_error(action, detail),
    do: {:error, {:reply_delivery, action, detail}}
end
