defmodule BullX.Config.ReqLLM do
  @moduledoc """
  Runtime configuration keys bridged into `req_llm` call-time settings.

  Nil means BullX leaves the corresponding `:req_llm` application environment
  key unset so upstream defaults remain in force.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:receive_timeout_ms,
    key: [:req_llm, :receive_timeout_ms],
    type: :integer,
    default: nil,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:metadata_timeout_ms,
    key: [:req_llm, :metadata_timeout_ms],
    type: :integer,
    default: nil,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:stream_completion_cleanup_after_ms,
    key: [:req_llm, :stream_completion_cleanup_after_ms],
    type: :integer,
    default: nil,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:debug,
    key: [:req_llm, :debug],
    type: :boolean,
    default: nil
  )

  @envdoc false
  bullx_env(:redact_context,
    key: [:req_llm, :redact_context],
    type: :boolean,
    default: nil
  )
end
