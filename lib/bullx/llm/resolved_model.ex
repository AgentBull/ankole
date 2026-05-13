defmodule BullX.LLM.ResolvedModel do
  @moduledoc false

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
