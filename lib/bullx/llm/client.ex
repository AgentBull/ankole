defmodule BullX.LLM.Client do
  @moduledoc false

  alias BullX.LLM.ResolvedModel

  @callback chat(ResolvedModel.t(), ReqLLM.Context.prompt(), keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}

  @callback stream_chat(ResolvedModel.t(), ReqLLM.Context.prompt(), keyword(), keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}

  @optional_callbacks stream_chat: 4
end
