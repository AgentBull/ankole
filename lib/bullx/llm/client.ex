defmodule BullX.LLM.Client do
  @moduledoc false

  alias BullX.LLM.ResolvedModel

  @callback chat(ResolvedModel.t(), ReqLLM.Context.prompt(), keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}
end
