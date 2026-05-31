defmodule BullX.LLM.ResolvedModel do
  @moduledoc """
  Runtime-ready model selection after resolving BullX provider configuration.

  Agent profiles refer to BullX provider/model ids. Resolution turns that pair
  into the ReqLLM provider atom, model input, and call options needed by the LLM
  client without leaking encrypted provider rows into runtime callers.
  """

  @enforce_keys [:provider_id, :model_id, :req_llm_provider, :model_input, :opts]
  defstruct [:provider_id, :model_id, :req_llm_provider, :model_input, opts: []]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          model_id: String.t(),
          req_llm_provider: atom(),
          model_input: map(),
          opts: keyword()
        }
end
