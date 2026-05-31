defmodule BullX.LLM.ResolvedProvider do
  @moduledoc """
  Runtime-ready provider configuration before a specific model is selected.

  The struct carries the BullX logical provider id together with the ReqLLM
  adapter and decrypted call options used to build model requests.
  """

  @enforce_keys [:provider_id, :req_llm_provider, :opts]
  defstruct [:provider_id, :req_llm_provider, :base_url, opts: []]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          req_llm_provider: atom(),
          base_url: String.t() | nil,
          opts: keyword()
        }
end
