defmodule Ankole.Plugins.EmailAdapter.ErrorPolicy do
  @moduledoc false

  @auth_codes ["530", "534", "535", "538"]

  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, {:smtp_open, _type, failure}}) do
    {:error, {:reply_delivery, open_action(failure), detail("smtp_session_failed", failure)}}
  end

  def normalize_delivery_result({:error, {:smtp_deliver, failure}}) do
    {:error, {:reply_delivery, deliver_action(failure), detail("smtp_delivery_failed", failure)}}
  end

  def normalize_delivery_result({:error, {:smtp_options, reason}}) do
    {:error,
     {:reply_delivery, :operator_action_required,
      %{"code" => "smtp_options_invalid", "reason" => bounded(reason)}}}
  end

  def normalize_delivery_result({:error, :no_recipients}),
    do: {:error, {:reply_delivery, :permanent, %{"code" => "email_no_recipients"}}}

  def normalize_delivery_result({:error, :attachments_too_large}),
    do: {:error, {:reply_delivery, :permanent, %{"code" => "email_attachments_too_large"}}}

  def normalize_delivery_result({:error, :signal_channel_not_found}),
    do: {:error, {:reply_delivery, :permanent, %{"code" => "email_channel_missing"}}}

  def normalize_delivery_result({:error, :outbound_attachment_path_missing}) do
    {:error, {:reply_delivery, :operator_action_required, %{"code" => "attachment_path_missing"}}}
  end

  def normalize_delivery_result({:error, %{"code" => code}}) when is_binary(code) do
    {:error,
     {:reply_delivery, :operator_action_required,
      %{"code" => "attachment_file_unavailable", "worker_file_code" => code}}}
  end

  def normalize_delivery_result({:error, reason})
      when reason in [:binding_config_not_found, :invalid_config_ref] do
    {:error, {:reply_delivery, :operator_action_required, %{"code" => Atom.to_string(reason)}}}
  end

  def normalize_delivery_result(result), do: result

  # Before DATA nothing reached the server, so a connection problem is safe to
  # retry; a rejected EHLO or login needs the operator.
  defp open_action({:permanent_failure, _host, _message}), do: :operator_action_required
  defp open_action({:temporary_failure, _host, :tls_failed}), do: :operator_action_required
  defp open_action({:temporary_failure, _host, _message}), do: :retryable
  defp open_action({:missing_requirement, _host, _requirement}), do: :operator_action_required

  defp open_action({:network_failure, _host, {:error, {:tls_alert, _alert}}}),
    do: :operator_action_required

  defp open_action({:network_failure, _host, {:error, {:options, _detail}}}),
    do: :operator_action_required

  defp open_action({:network_failure, _host, _reason}), do: :retryable
  defp open_action({:unexpected_response, _host, _lines}), do: :retryable
  defp open_action(_failure), do: :operator_action_required

  defp deliver_action({:permanent_failure, message}) do
    if auth_reply?(message), do: :operator_action_required, else: :permanent
  end

  defp deliver_action({:temporary_failure, _message}), do: :retryable
  defp deliver_action({:missing_requirement, _requirement}), do: :operator_action_required
  defp deliver_action(_failure), do: :retryable

  defp auth_reply?(message) do
    text = IO.iodata_to_binary(List.wrap(to_binary(message)))
    Enum.any?(@auth_codes, &String.starts_with?(text, &1))
  end

  defp detail(code, failure) do
    %{"code" => code, "failure" => bounded(failure)}
  end

  defp bounded(term) do
    term
    |> to_binary()
    |> String.slice(0, 300)
  end

  defp to_binary(term) when is_binary(term), do: term
  defp to_binary(term), do: inspect(term)
end
