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

  @spec sync_all() :: :ok
  def sync_all do
    Enum.each(@settings, &sync_setting/1)
    :ok
  end

  @spec sync_if_req_llm_key(String.t()) :: :ok
  def sync_if_req_llm_key(@prefix <> _suffix), do: sync_all()
  def sync_if_req_llm_key(_key), do: :ok

  defp sync_setting({accessor, req_llm_key}) do
    case apply(BullX.Config.ReqLLM, accessor, []) do
      {:ok, nil} -> Application.delete_env(:req_llm, req_llm_key)
      {:ok, value} -> Application.put_env(:req_llm, req_llm_key, value)
      {:error, _reason} -> Application.delete_env(:req_llm, req_llm_key)
    end
  end
end
