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
          required(:tool_calls) => [term()],
          required(:provider_meta) => map(),
          required(:message) => ReqLLM.Message.t() | nil
        }

  @spec chat(String.t(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, chat_result()} | {:error, term()}
  def chat(model_spec, messages, opts \\ []) when is_binary(model_spec) and is_list(opts) do
    with {:ok, resolved} <- Catalog.resolve_model_spec(model_spec),
         {:ok, %Response{} = response} <- client().chat(resolved, messages, opts) do
      {:ok, response_result(response, resolved)}
    end
  end

  @spec stream_chat(String.t(), ReqLLM.Context.prompt(), keyword(), keyword()) ::
          {:ok, chat_result()} | {:error, term()}
  def stream_chat(model_spec, messages, opts, stream_opts)
      when is_binary(model_spec) and is_list(opts) and is_list(stream_opts) do
    with {:ok, resolved} <- Catalog.resolve_model_spec(model_spec),
         {:ok, %Response{} = response} <-
           call_stream_client(resolved, messages, opts, stream_opts) do
      {:ok, response_result(response, resolved)}
    end
  end

  defp call_stream_client(resolved, messages, opts, stream_opts) do
    llm_client = client()

    case function_exported?(llm_client, :stream_chat, 4) do
      true ->
        llm_client.stream_chat(resolved, messages, opts, stream_opts)

      false ->
        with {:ok, %Response{} = response} <- llm_client.chat(resolved, messages, opts) do
          on_result = Keyword.get(stream_opts, :on_result)

          if is_function(on_result, 1) do
            on_result.(Response.text(response) || "")
          end

          {:ok, response}
        end
    end
  end

  defp response_result(%Response{} = response, resolved) do
    %{
      text: Response.text(response) || "",
      provider_id: resolved.provider_id,
      model_id: resolved.model_id,
      usage: Response.usage(response),
      finish_reason: Response.finish_reason(response),
      tool_calls: Response.tool_calls(response),
      provider_meta: response.provider_meta || %{},
      message: response.message
    }
  end

  defp client do
    :bullx
    |> Application.get_env(:llm, [])
    |> Keyword.get(:client, BullX.LLM.ReqClient)
  end
end
