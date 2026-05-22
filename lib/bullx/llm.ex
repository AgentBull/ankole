defmodule BullX.LLM do
  @moduledoc """
  Public LLM call boundary for BullX runtimes.

  Callers own the model spec. This module resolves the spec through the BullX
  provider catalog, delegates the provider request to the configured client, and
  returns a small provider-neutral chat result.
  """

  alias BullX.LLM.{Catalog, ModelConfig}
  alias ReqLLM.Message.ContentPart
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

  @spec chat(String.t() | ModelConfig.t(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, chat_result()} | {:error, term()}
  def chat(model, messages, opts \\ []) when is_list(opts) do
    with {:ok, resolved, opts} <- resolve_call(model, opts),
         messages <- normalize_message_text_parts(messages),
         {:ok, %Response{} = response} <- client().chat(resolved, messages, opts) do
      {:ok, response_result(response, resolved)}
    end
  end

  @spec stream_chat(String.t() | ModelConfig.t(), ReqLLM.Context.prompt(), keyword(), keyword()) ::
          {:ok, chat_result()} | {:error, term()}
  def stream_chat(model, messages, opts, stream_opts)
      when is_list(opts) and is_list(stream_opts) do
    with {:ok, resolved, opts} <- resolve_call(model, opts),
         messages <- normalize_message_text_parts(messages),
         {:ok, %Response{} = response} <-
           call_stream_client(resolved, messages, opts, stream_opts) do
      {:ok, response_result(response, resolved)}
    end
  end

  defp resolve_call(%ModelConfig{} = config, opts) do
    with {:ok, resolved} <- Catalog.resolve_model_config(config) do
      {:ok, resolved, Keyword.merge(ModelConfig.call_opts(config), opts)}
    end
  end

  defp resolve_call(model_spec, opts) when is_binary(model_spec) do
    with {:ok, resolved} <- Catalog.resolve_model_spec(model_spec) do
      {:ok, resolved, opts}
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

  defp normalize_message_text_parts(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message_text_part/1)
  end

  defp normalize_message_text_parts(prompt), do: prompt

  defp normalize_message_text_part(%ReqLLM.Message{role: role, content: content} = message)
       when is_list(content) do
    case text_merge_role?(role) do
      true -> %{message | content: merge_text_only_content(content)}
      false -> message
    end
  end

  defp normalize_message_text_part(%{role: role, content: content} = message)
       when is_list(content) do
    case text_merge_role?(role) do
      true -> %{message | content: merge_text_only_content(content)}
      false -> message
    end
  end

  defp normalize_message_text_part(%{"role" => role, "content" => content} = message)
       when is_list(content) do
    case text_merge_role?(role) do
      true -> %{message | "content" => merge_text_only_content(content)}
      false -> message
    end
  end

  defp normalize_message_text_part(message), do: message

  defp text_merge_role?(:system), do: true
  defp text_merge_role?(:user), do: true
  defp text_merge_role?("system"), do: true
  defp text_merge_role?("user"), do: true
  defp text_merge_role?(_role), do: false

  defp merge_text_only_content(content) do
    case text_only_parts(content) do
      {:ok, [_single]} ->
        content

      {:ok, [_first, _second | _rest] = texts} ->
        [ContentPart.text(Enum.join(texts, "\n"), merged_text_metadata(content))]

      _not_text_only ->
        content
    end
  end

  defp text_only_parts(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case text_part_text(part) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      :error -> :error
    end
  end

  defp text_part_text(%ContentPart{type: :text, text: text}) when is_binary(text),
    do: {:ok, text}

  defp text_part_text(%{type: :text, text: text}) when is_binary(text),
    do: {:ok, text}

  defp text_part_text(%{"type" => "text", "text" => text}) when is_binary(text),
    do: {:ok, text}

  defp text_part_text(_part), do: :error

  defp merged_text_metadata(content) do
    content
    |> Enum.map(&text_part_metadata/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp text_part_metadata(%ContentPart{type: :text, metadata: metadata}) when is_map(metadata),
    do: metadata

  defp text_part_metadata(%{type: :text, metadata: metadata}) when is_map(metadata),
    do: metadata

  defp text_part_metadata(%{"type" => "text", "metadata" => metadata}) when is_map(metadata),
    do: metadata

  defp text_part_metadata(_part), do: %{}

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
