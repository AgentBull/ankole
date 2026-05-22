defmodule BullX.AIAgent.Tools.Error do
  @moduledoc """
  Safe structured tool error returned to the Agentic Loop.
  """

  @codes [
    :tool_unknown,
    :tool_disabled,
    :tool_unavailable,
    :tool_denied,
    :tool_malformed_arguments,
    :tool_timeout,
    :tool_failed
  ]

  @enforce_keys [:code, :message]
  defstruct [:code, :message, retryable: false]

  @type code ::
          :tool_unknown
          | :tool_disabled
          | :tool_unavailable
          | :tool_denied
          | :tool_malformed_arguments
          | :tool_timeout
          | :tool_failed

  @type t :: %__MODULE__{code: code(), message: String.t(), retryable: boolean()}

  @spec new(code(), String.t(), boolean()) :: t()
  def new(code, message, retryable \\ false)
      when code in @codes and is_binary(message) and is_boolean(retryable) do
    %__MODULE__{code: code, message: String.slice(message, 0, 200), retryable: retryable}
  end

  @spec to_result(t()) :: map()
  def to_result(%__MODULE__{} = error) do
    %{
      "ok" => false,
      "error" => %{
        "code" => Atom.to_string(error.code),
        "message" => error.message,
        "retryable" => error.retryable
      }
    }
  end
end
