defmodule BullX.Config.ReqLLM.Bridge do
  @moduledoc false

  @prefix "bullx.req_llm."

  @settings [
    receive_timeout_ms: :receive_timeout,
    metadata_timeout_ms: :metadata_timeout,
    stream_completion_cleanup_after_ms: :stream_completion_cleanup_after,
    debug: :debug,
    redact_context: :redact_context
  ]

  @spec sync_all() :: :ok | {:error, term()}
  def sync_all do
    @settings
    |> Enum.reduce([], &collect_sync_error/2)
    |> sync_result()
  end

  @spec sync_if_req_llm_key(String.t()) :: :ok | {:error, term()}
  def sync_if_req_llm_key(@prefix <> _suffix), do: sync_all()
  def sync_if_req_llm_key(_key), do: :ok

  defp collect_sync_error(setting, acc) do
    case sync_setting(setting) do
      :ok -> acc
      {:error, reason} -> [reason | acc]
    end
  end

  defp sync_result([]), do: :ok
  defp sync_result([reason]), do: {:error, reason}

  defp sync_result(reasons),
    do: {:error, {:multiple_req_llm_projection_failures, Enum.reverse(reasons)}}

  defp sync_setting({accessor, req_llm_key}) do
    case apply(BullX.Config.ReqLLM, accessor, []) do
      {:ok, nil} ->
        Application.delete_env(:req_llm, req_llm_key)
        :ok

      {:ok, value} ->
        Application.put_env(:req_llm, req_llm_key, value)
        :ok

      {:error, reason} ->
        {:error, {:req_llm_setting_failed, accessor, req_llm_key, reason}}
    end
  end
end
