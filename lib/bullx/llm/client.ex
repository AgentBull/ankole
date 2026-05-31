defmodule BullX.LLM.Client do
  @moduledoc """
  Behaviour for the LLM client boundary used by AIAgent runtime code.

  The default implementation delegates to ReqLLM, but tests and future runtime
  policies can swap this boundary without changing Agent orchestration.
  """

  alias BullX.LLM.ResolvedModel

  @callback chat(ResolvedModel.t(), ReqLLM.Context.prompt(), keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}

  @callback stream_chat(ResolvedModel.t(), ReqLLM.Context.prompt(), keyword(), keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}

  @optional_callbacks stream_chat: 4
end
