defmodule BullX.AIAgent.Tools.Context do
  @moduledoc """
  Explicit runtime facts passed to BullX-owned AIAgent tools.
  """

  @enforce_keys [
    :caller_principal_id,
    :agent_principal_id,
    :conversation_id,
    :source_type,
    :source_id,
    :tool_call_id,
    :tool_name,
    :effective_access,
    :timeout_ms,
    :idempotency_key
  ]
  defstruct [
    :caller_principal_id,
    :agent_principal_id,
    :conversation_id,
    :source_type,
    :source_id,
    :tool_call_id,
    :tool_name,
    :effective_access,
    :timeout_ms,
    :deadline_at_ms,
    :idempotency_key,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec deadline_remaining_ms(t()) :: non_neg_integer() | nil
  def deadline_remaining_ms(%__MODULE__{deadline_at_ms: nil}), do: nil

  def deadline_remaining_ms(%__MODULE__{deadline_at_ms: deadline_at_ms})
      when is_integer(deadline_at_ms) do
    max(deadline_at_ms - System.system_time(:millisecond), 0)
  end

  def deadline_remaining_ms(%__MODULE__{}), do: nil

  @spec clamp_timeout_ms(t(), pos_integer()) :: non_neg_integer()
  def clamp_timeout_ms(%__MODULE__{} = context, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    case deadline_remaining_ms(context) do
      nil -> timeout_ms
      remaining_ms -> min(timeout_ms, remaining_ms)
    end
  end

  @spec clamp_req_options(t(), keyword()) :: keyword()
  def clamp_req_options(%__MODULE__{} = context, opts) when is_list(opts) do
    case deadline_remaining_ms(context) do
      nil ->
        opts

      remaining_ms ->
        receive_timeout = Keyword.get(opts, :receive_timeout, remaining_ms)
        Keyword.put(opts, :receive_timeout, clamp_receive_timeout(receive_timeout, remaining_ms))
    end
  end

  defp clamp_receive_timeout(receive_timeout, remaining_ms) when is_integer(receive_timeout) do
    min(receive_timeout, remaining_ms)
  end

  defp clamp_receive_timeout(_receive_timeout, remaining_ms), do: remaining_ms
end
