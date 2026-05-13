defmodule BullX.LLM do
  @moduledoc """
  Public LLM call boundary for BullX runtimes.

  Callers own the model spec. This module resolves the spec through the BullX
  provider catalog, delegates the provider request to the configured client, and
  returns a small provider-neutral chat result.
  """

  alias BullX.LLM.Catalog
  alias ReqLLM.Response

  @type chat_result :: %{
          required(:text) => String.t(),
          required(:provider_id) => String.t(),
          required(:model_id) => String.t(),
          required(:usage) => map() | nil,
          required(:finish_reason) => atom() | nil,
          required(:provider_meta) => map()
        }

  @spec chat(String.t(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, chat_result()} | {:error, term()}
  def chat(model_spec, messages, opts \\ []) when is_binary(model_spec) and is_list(opts) do
    with {:ok, resolved} <- Catalog.resolve_model_spec(model_spec),
         {:ok, %Response{} = response} <- client().chat(resolved, messages, opts) do
      {:ok,
       %{
         text: Response.text(response) || "",
         provider_id: resolved.provider_id,
         model_id: resolved.model_id,
         usage: Response.usage(response),
         finish_reason: Response.finish_reason(response),
         provider_meta: response.provider_meta || %{}
       }}
    end
  end

  defp client do
    :bullx
    |> Application.get_env(:llm, [])
    |> Keyword.get(:client, BullX.LLM.ReqClient)
  end
end
