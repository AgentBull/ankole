defmodule BullX.LLM.ReqClient do
  @moduledoc false

  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, messages, opts) when is_list(opts) do
    ReqLLM.generate_text(resolved.model_input, messages, Keyword.merge(resolved.opts, opts))
  end

  @impl BullX.LLM.Client
  def stream_chat(%ResolvedModel{} = resolved, messages, opts, stream_opts)
      when is_list(opts) and is_list(stream_opts) do
    with {:ok, stream_response} <-
           ReqLLM.stream_text(resolved.model_input, messages, Keyword.merge(resolved.opts, opts)) do
      ReqLLM.StreamResponse.process_stream(stream_response, stream_opts)
    end
  end
end
