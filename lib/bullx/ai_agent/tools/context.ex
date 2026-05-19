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
    :idempotency_key,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}
end
