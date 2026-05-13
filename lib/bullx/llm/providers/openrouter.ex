defmodule BullX.LLM.Providers.OpenRouter do
  @moduledoc """
  BullX OpenRouter provider.

  This registers as `:openrouter` and overrides req_llm's built-in OpenRouter
  provider. BullX keeps the same public provider id while encoding reasoning
  defaults with OpenRouter's unified `reasoning` request object.
  """

  use ReqLLM.Provider,
    id: :openrouter,
    default_base_url: "https://openrouter.ai/api/v1",
    default_env_key: "OPENROUTER_API_KEY"

  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh, :default]

  @provider_schema ReqLLM.Providers.OpenRouter.provider_schema().schema
                   |> Keyword.put(:openrouter_reasoning_effort,
                     type: {:in, @reasoning_efforts},
                     doc: "OpenRouter reasoning effort default. Encoded as reasoning.effort."
                   )
                   |> Keyword.put(:openrouter_reasoning,
                     type: :map,
                     doc:
                       "OpenRouter unified reasoning object, e.g. %{effort: \"high\"} or %{max_tokens: 2000}."
                   )

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    request =
      ReqLLM.Provider.Defaults.default_attach(
        __MODULE__,
        request,
        model_input,
        user_opts
      )

    maybe_add_attribution_headers(request, user_opts)
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    opts =
      case Keyword.get(provider_opts, :openrouter_structured_output_mode) do
        :json_schema ->
          prepare_json_schema_object_opts(opts, provider_opts, compiled_schema)

        _other ->
          prepare_tool_object_opts(opts, compiled_schema)
      end

    opts =
      opts
      |> put_object_max_tokens()
      |> Keyword.put(:operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, :chat, model_spec, prompt, opts)
  end

  def prepare_request(:embedding, _model_spec, _input, _opts) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: :embedding not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    {reasoning_token_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

    {translated_opts, warnings} =
      ReqLLM.Providers.OpenRouter.translate_options(operation, model, opts)

    {put_reasoning_token_budget(translated_opts, reasoning_token_budget), warnings}
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    request
    |> ReqLLM.Provider.Defaults.encode_body_from_map(build_body(request))
    |> maybe_add_attribution_headers(request.options)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    request
    |> ReqLLM.Providers.OpenRouter.build_body()
    |> Map.delete(:reasoning_effort)
    |> Map.delete("reasoning_effort")
    |> put_reasoning(request.options)
  end

  @impl ReqLLM.Provider
  def decode_response(request_response) do
    ReqLLM.Providers.OpenRouter.decode_response(request_response)
  end

  defp prepare_json_schema_object_opts(opts, provider_opts, compiled_schema) do
    json_schema_payload = %{
      type: "json_schema",
      json_schema: %{
        name: "structured_output",
        strict: true,
        schema: ReqLLM.Schema.to_json(compiled_schema.schema)
      }
    }

    updated_provider_opts =
      provider_opts
      |> Keyword.put(:response_format, json_schema_payload)
      |> Keyword.delete(:openrouter_structured_output_mode)

    opts
    |> Keyword.put(:provider_options, updated_provider_opts)
    |> Keyword.delete(:tools)
    |> Keyword.delete(:tool_choice)
  end

  defp prepare_tool_object_opts(opts, compiled_schema) do
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts
    |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
    |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
    |> Keyword.delete(:response_format)
  end

  defp put_object_max_tokens(opts) do
    case Keyword.get(opts, :max_tokens) do
      nil -> Keyword.put(opts, :max_tokens, 4096)
      tokens when tokens < 200 -> Keyword.put(opts, :max_tokens, 200)
      _tokens -> opts
    end
  end

  defp put_reasoning_token_budget(opts, nil), do: opts

  defp put_reasoning_token_budget(opts, token_budget) do
    Keyword.put_new(opts, :openrouter_reasoning, %{max_tokens: token_budget})
  end

  defp put_reasoning(body, options) do
    case normalized_reasoning(options) do
      nil -> body
      reasoning -> Map.put(body, :reasoning, reasoning)
    end
  end

  defp normalized_reasoning(options) do
    case options[:openrouter_reasoning] do
      reasoning when is_map(reasoning) and map_size(reasoning) > 0 ->
        reasoning

      _other ->
        options[:openrouter_reasoning_effort]
        |> case do
          nil -> options[:reasoning_effort]
          effort -> effort
        end
        |> reasoning_from_effort()
    end
  end

  defp reasoning_from_effort(nil), do: nil
  defp reasoning_from_effort(:default), do: nil
  defp reasoning_from_effort("default"), do: nil
  defp reasoning_from_effort(effort), do: %{effort: effort}

  defp maybe_add_attribution_headers(request, opts) do
    request
    |> maybe_put_header("HTTP-Referer", opts[:app_referer] || request.options[:app_referer])
    |> maybe_put_header("X-Title", opts[:app_title] || request.options[:app_title])
  end

  defp maybe_put_header(request, _header, value) when not is_binary(value), do: request

  defp maybe_put_header(request, header, value) do
    Req.Request.put_header(request, header, value)
  end
end
