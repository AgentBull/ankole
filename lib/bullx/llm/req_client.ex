defmodule BullX.LLM.ReqClient do
  @moduledoc false

  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, messages, opts) when is_list(opts) do
    ReqLLM.generate_text(resolved.model_input, messages, Keyword.merge(resolved.opts, opts))
  end
end
