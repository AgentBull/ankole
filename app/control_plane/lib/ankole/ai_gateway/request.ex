defmodule Ankole.AIGateway.Request do
  @moduledoc """
  Builds provider-facing HTTP request maps from the public AIGateway request body.

  This module is intentionally small and data-only. It does not call Req, keep
  credentials, or decide which provider is selected. The resolver has already
  produced a runtime map; provider modules use this module to translate that map
  and the public body into the exact upstream wire shape they own.
  """

  import Ankole.AIGateway.MapUtils, only: [maybe_put: 3, normalize_request_keys: 1]

  alias Ankole.AIGateway.Providers

  @default_timeout_ms 60_000

  @doc """
  Builds a default OpenAI-compatible request for the selected response endpoint.

  Provider modules usually call a more specific builder directly. This function
  exists for the simple OpenAI-compatible path where the endpoint mode can be
  read from runtime connection options.
  """
  @spec build_response_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_response_request(runtime, request) do
    build_openai_compatible_response_request(
      runtime,
      request,
      Providers.response_endpoint_mode(runtime),
      stream?: false
    )
  end

  @doc """
  Builds either a Responses API or Chat Completions API request.

  The public request is kept in `:public_request` because response normalization
  may need fields that some upstream APIs omit in their response body. The v1
  gateway accepts `previous_response_id` for wire compatibility but strips it
  before dispatch because v1 has no persisted response store.
  """
  @spec build_openai_compatible_response_request(map(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_openai_compatible_response_request(runtime, request, endpoint_mode, opts \\ []) do
    stream? = Keyword.get(opts, :stream?, false)

    public_request =
      runtime
      |> merge_provider_options(request)
      |> Map.delete("previous_response_id")
      |> Map.put("stream", stream?)
      |> Map.put("model", runtime["model"])

    case endpoint_mode do
      "responses" ->
        with {:ok, upstream_request} <- build_json_request(runtime, "responses", public_request) do
          {:ok, Map.put(upstream_request, :public_request, public_request)}
        end

      "chat_completions" ->
        public_request
        |> chat_completions_body(runtime["model"], stream?)
        |> then(
          &build_json_request(runtime, "chat/completions", &1, response_mode: "chat_completions")
        )
        |> case do
          {:ok, upstream_request} ->
            {:ok, Map.put(upstream_request, :public_request, public_request)}

          {:error, reason} ->
            {:error, reason}
        end

      mode ->
        {:error, {:unsupported_response_endpoint_mode, mode}}
    end
  end

  @doc """
  Builds an Anthropic Messages request from the public Responses-style body.

  Claude is not treated as an OpenAI-compatible pass-through provider. This
  builder maps system instructions, messages, tools, and tool choice into the
  Messages API shape while preserving the public request for downstream
  normalization.
  """
  @spec build_anthropic_response_request(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_anthropic_response_request(runtime, request, opts \\ []) do
    stream? = Keyword.get(opts, :stream?, false)

    public_request =
      runtime
      |> merge_provider_options(request)
      |> Map.delete("previous_response_id")
      |> Map.put("stream", stream?)
      |> Map.put("model", runtime["model"])

    body =
      %{}
      |> maybe_put("system", Map.get(public_request, "instructions"))
      |> maybe_put(
        "max_tokens",
        Map.get(public_request, "max_output_tokens") || Map.get(public_request, "max_tokens") ||
          4096
      )
      |> maybe_put("temperature", Map.get(public_request, "temperature"))
      |> maybe_put("top_p", Map.get(public_request, "top_p"))
      |> maybe_put("metadata", Map.get(public_request, "metadata"))
      |> maybe_put("tools", anthropic_tools(Map.get(public_request, "tools")))
      |> maybe_put("tool_choice", anthropic_tool_choice(Map.get(public_request, "tool_choice")))
      |> Map.put("model", runtime["model"])
      |> Map.put("stream", stream?)
      |> Map.put("messages", anthropic_messages(Map.get(public_request, "input")))

    # Anthropic's official base URL is the account root, so the default path is
    # `v1/messages`. Anthropic-compatible routers such as OpenRouter may expose
    # the same wire contract under a versioned base URL like `/api/v1`, where the
    # path must be just `messages`. Keeping this as a provider connection option
    # avoids hard-coding router-specific URL rules in the Claude adapter.
    path =
      runtime
      |> get_in(["connection_options", "messages_path"])
      |> anthropic_messages_path()

    with {:ok, upstream_request} <-
           build_json_request(runtime, path, body, response_mode: "anthropic_messages") do
      {:ok, Map.put(upstream_request, :public_request, public_request)}
    end
  end

  @doc """
  Builds an Azure OpenAI request for deployment-scoped and `/openai/v1` endpoints.

  Azure has two useful wire families here: traditional deployment paths where
  the model is encoded in the URL, and newer `/openai/v1` paths where the body
  keeps a normal model field. The returned request tracks which choice was made
  so body normalization can stay OpenAI-compatible.
  """
  @spec build_azure_openai_response_request(map(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_azure_openai_response_request(runtime, request, endpoint_mode, opts \\ []) do
    stream? = Keyword.get(opts, :stream?, false)
    options = Map.get(runtime, "connection_options", %{})

    with {:ok, path, include_model?} <- azure_response_path(runtime, endpoint_mode, options) do
      public_request =
        runtime
        |> merge_provider_options(request)
        |> Map.delete("previous_response_id")
        |> Map.put("stream", stream?)
        |> Map.put("model", runtime["model"])

      body =
        case endpoint_mode do
          "responses" ->
            if include_model?, do: public_request, else: Map.delete(public_request, "model")

          "chat_completions" ->
            public_request
            |> chat_completions_body(runtime["model"], stream?)
            |> maybe_delete_model(include_model?)
        end

      with {:ok, upstream_request} <-
             build_json_request(runtime, path, body, response_mode: endpoint_mode) do
        {:ok, Map.put(upstream_request, :public_request, public_request)}
      end
    end
  end

  @doc """
  Builds the common JSON request map used by all provider dispatch paths.

  JSON encoding is deliberately not done here. `HttpClient` owns the final
  `Ankole.JSON` encoding boundary so tests and provider code can inspect maps.
  """
  @spec build_json_request(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_json_request(runtime, path, request, opts \\ []) do
    with {:ok, url} <- endpoint_url(runtime, path),
         {:ok, headers} <- Providers.request_headers(runtime),
         {:ok, body} <- request_body(runtime, request, opts) do
      {:ok,
       %{
         method: :post,
         url: url,
         headers: headers,
         body: body,
         http_protocol: Providers.http_protocol(runtime),
         timeout_ms: @default_timeout_ms,
         path: path,
         response_mode: Keyword.get(opts, :response_mode) || response_endpoint_mode_for_path(path)
       }}
    end
  end

  @doc """
  Validates the public embedding request before provider dispatch.

  Invalid local request shape fails before any upstream call so a bad selector or
  malformed payload cannot accidentally leak to a provider as a retry candidate.
  """
  @spec validate_embeddings_request(map()) :: :ok | {:error, term()}
  def validate_embeddings_request(request) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "input") ->
        {:error, :missing_input}

      embedding_input?(Map.get(request, "input")) ->
        :ok

      true ->
        {:error, :invalid_embedding_input}
    end
  end

  @doc """
  Validates the public rerank request before provider dispatch.
  """
  @spec validate_rerank_request(map()) :: :ok | {:error, term()}
  def validate_rerank_request(request) do
    request = normalize_request_keys(request)

    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      not rerank_documents?(Map.get(request, "documents")) ->
        {:error, :invalid_documents}

      not valid_top_n?(Map.get(request, "top_n")) ->
        {:error, :invalid_top_n}

      true ->
        :ok
    end
  end

  defp response_endpoint_mode_for_path("responses"), do: "responses"
  defp response_endpoint_mode_for_path("chat/completions"), do: "chat_completions"
  defp response_endpoint_mode_for_path(_path), do: "json"

  defp endpoint_url(%{"connection_options" => %{"base_url" => base_url} = options}, path)
       when is_binary(base_url) do
    case String.trim(base_url) do
      "" ->
        {:error, :missing_base_url}

      base_url ->
        url =
          "#{String.trim_trailing(base_url, "/")}/#{String.trim_leading(path, "/")}"
          |> append_query_params(Map.get(options, "query_params"))

        {:ok, url}
    end
  end

  defp endpoint_url(_runtime, _path), do: {:error, :missing_base_url}

  # Vector endpoints mostly pass through provider-specific options, while LLM
  # response builders merge provider options before converting the body. Keeping
  # this switch explicit prevents hidden option merging across capability kinds.
  defp request_body(runtime, request, opts) do
    request =
      if Keyword.get(opts, :merge_provider_options?, false) do
        merge_provider_options(runtime, request)
      else
        normalize_request_keys(request)
      end

    request =
      if Keyword.get(opts, :inject_model?, false) do
        Map.put(request, "model", runtime["model"])
      else
        request
      end

    {:ok, request}
  end

  defp embedding_input?(input) when is_binary(input), do: String.trim(input) != ""

  defp embedding_input?(input) when is_list(input) and input != [] do
    Enum.all?(input, fn
      value when is_binary(value) -> true
      value when is_integer(value) -> true
      value when is_map(value) -> true
      value when is_list(value) -> Enum.all?(value, &is_integer/1)
      _value -> false
    end)
  end

  defp embedding_input?(_input), do: false

  defp rerank_documents?(documents) when is_list(documents) and documents != [] do
    Enum.all?(documents, fn
      document when is_binary(document) -> String.trim(document) != ""
      document when is_map(document) -> map_size(document) > 0
      _document -> false
    end)
  end

  defp rerank_documents?(_documents), do: false

  defp valid_top_n?(nil), do: true
  defp valid_top_n?(value) when is_integer(value), do: value > 0
  defp valid_top_n?(_value), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp merge_provider_options(runtime, request) do
    options =
      case Map.get(runtime, "provider_options") do
        value when is_map(value) -> normalize_request_keys(value)
        _value -> %{}
      end

    Map.merge(options, normalize_request_keys(request))
  end

  # Chat Completions accepts a smaller and older request shape than Responses.
  # This conversion keeps only fields that are meaningful on that wire API and
  # moves the public `input` array into chat messages.
  defp chat_completions_body(request, model, stream?) do
    request = normalize_request_keys(request)

    %{}
    |> maybe_put("temperature", Map.get(request, "temperature"))
    |> maybe_put("top_p", Map.get(request, "top_p"))
    |> maybe_put("presence_penalty", Map.get(request, "presence_penalty"))
    |> maybe_put("frequency_penalty", Map.get(request, "frequency_penalty"))
    |> maybe_put("parallel_tool_calls", Map.get(request, "parallel_tool_calls"))
    |> maybe_put("service_tier", Map.get(request, "service_tier"))
    |> maybe_put("user", Map.get(request, "user"))
    |> maybe_put("top_logprobs", Map.get(request, "top_logprobs"))
    |> maybe_put("response_format", chat_response_format(request))
    |> maybe_put(
      "max_tokens",
      Map.get(request, "max_output_tokens") || Map.get(request, "max_tokens")
    )
    |> maybe_put("tools", chat_tools(Map.get(request, "tools")))
    |> maybe_put("tool_choice", chat_tool_choice(Map.get(request, "tool_choice")))
    |> maybe_put("metadata", Map.get(request, "metadata"))
    |> maybe_put("stream_options", chat_stream_options(request, stream?))
    |> Map.put("model", model)
    |> Map.put("stream", stream?)
    |> Map.put("messages", chat_messages(request))
  end

  # Include usage by default for streaming Chat Completions because token usage
  # usually appears only in the final chunk when this option is present.
  defp chat_stream_options(request, true) do
    request
    |> Map.get("stream_options")
    |> case do
      value when is_map(value) -> Map.put_new(value, "include_usage", true)
      _value -> %{"include_usage" => true}
    end
  end

  defp chat_stream_options(_request, false), do: nil

  # Responses asks for structured output under `text.format`, while Chat
  # Completions expects `response_format`. Keeping this translation in the
  # adapter prevents worker callers from knowing which upstream API family a
  # provider uses.
  defp chat_response_format(%{"response_format" => response_format}) when is_map(response_format),
    do: response_format

  defp chat_response_format(%{"text" => %{"format" => %{"type" => "json_schema"} = format}}) do
    json_schema =
      %{}
      |> maybe_put("name", Map.get(format, "name") || "response")
      |> maybe_put("description", Map.get(format, "description"))
      |> maybe_put("schema", Map.get(format, "schema"))
      |> maybe_put("strict", Map.get(format, "strict"))

    %{"type" => "json_schema", "json_schema" => json_schema}
  end

  defp chat_response_format(%{"text" => %{"format" => %{"type" => "json_object"}}}),
    do: %{"type" => "json_object"}

  defp chat_response_format(_request), do: nil

  defp chat_messages(request) do
    system_messages =
      case Map.get(request, "instructions") do
        value when is_binary(value) and value != "" -> [%{"role" => "system", "content" => value}]
        _value -> []
      end

    system_messages ++ input_messages(Map.get(request, "input"))
  end

  defp input_messages(input) when is_binary(input), do: [%{"role" => "user", "content" => input}]

  defp input_messages(input) when is_list(input) do
    Enum.flat_map(input, fn
      %{"role" => role, "content" => content} when is_binary(role) ->
        [chat_message(role, content)]

      %{"type" => "message", "role" => role, "content" => content} when is_binary(role) ->
        [chat_message(role, content)]

      value ->
        [%{"role" => "user", "content" => content_to_text(value)}]
    end)
  end

  defp input_messages(_input), do: []

  defp chat_message(role, content) do
    role = normalize_chat_role(role)
    %{"role" => role, "content" => chat_message_content(role, content)}
  end

  # Chat Completions has no `developer` role. Mapping it to `system` preserves
  # the instruction intent on compatible providers without inventing a new role.
  defp normalize_chat_role("developer"), do: "system"
  defp normalize_chat_role("system"), do: "system"
  defp normalize_chat_role("assistant"), do: "assistant"
  defp normalize_chat_role(_role), do: "user"

  defp chat_message_content("user", content) when is_list(content) do
    case Enum.map(content, &chat_user_content_part/1) do
      [] -> ""
      parts -> parts
    end
  end

  defp chat_message_content(_role, content), do: content_to_text(content)

  defp chat_user_content_part(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"],
       do: %{"type" => "text", "text" => to_string(text)}

  # Responses uses `input_image`; Chat Completions uses `image_url`. The content
  # is preserved instead of being flattened to text so multimodal providers still
  # receive the image payload.
  defp chat_user_content_part(%{"type" => "input_image", "image_url" => image_url}),
    do: chat_image_url_part(image_url)

  defp chat_user_content_part(%{"type" => "image_url", "image_url" => image_url}),
    do: chat_image_url_part(image_url)

  defp chat_user_content_part(%{"text" => text}),
    do: %{"type" => "text", "text" => to_string(text)}

  defp chat_user_content_part(part),
    do: %{"type" => "text", "text" => inspect(part)}

  defp chat_image_url_part(%{"url" => url} = image_url) when is_binary(url),
    do: %{"type" => "image_url", "image_url" => image_url}

  defp chat_image_url_part(url) when is_binary(url),
    do: %{"type" => "image_url", "image_url" => %{"url" => url}}

  defp chat_image_url_part(image_url),
    do: %{"type" => "text", "text" => inspect(image_url)}

  # The public gateway follows the Responses tool shape, while Chat Completions
  # nests function details under `function`. Without this conversion real
  # OpenAI-compatible routers reject tool calls even though mock tests can pass.
  defp chat_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"type" => "function", "function" => function} = tool when is_map(function) ->
        [%{"type" => "function", "function" => chat_function_tool(function, tool)}]

      %{"type" => "function"} = tool ->
        [%{"type" => "function", "function" => chat_function_tool(tool, tool)}]

      tool when is_map(tool) ->
        [tool]

      _tool ->
        []
    end)
  end

  defp chat_tools(_tools), do: nil

  defp chat_function_tool(function, tool) do
    %{}
    |> maybe_put("name", Map.get(function, "name"))
    |> maybe_put("description", Map.get(function, "description"))
    |> maybe_put(
      "parameters",
      Map.get(function, "parameters") || Map.get(function, "input_schema") ||
        %{"type" => "object"}
    )
    |> maybe_put("strict", Map.get(function, "strict") || Map.get(tool, "strict"))
  end

  defp chat_tool_choice(%{"type" => "function", "function" => %{"name" => _name}} = choice),
    do: choice

  defp chat_tool_choice(%{"type" => "function", "name" => name}) when is_binary(name),
    do: %{"type" => "function", "function" => %{"name" => name}}

  defp chat_tool_choice(choice), do: choice

  defp append_query_params(url, params) when is_map(params) and map_size(params) > 0 do
    encoded = URI.encode_query(params)
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> encoded
  end

  defp append_query_params(url, _params), do: url

  # Anthropic Messages uses user/assistant messages with typed content blocks.
  # Function-call outputs become `tool_result` blocks in a user message.
  defp anthropic_messages(input) when is_binary(input) do
    [%{"role" => "user", "content" => [%{"type" => "text", "text" => input}]}]
  end

  defp anthropic_messages(input) when is_list(input) do
    Enum.flat_map(input, fn
      %{"type" => "message", "role" => role, "content" => content} when is_binary(role) ->
        [%{"role" => anthropic_role(role), "content" => anthropic_content(content)}]

      %{"role" => role, "content" => content} when is_binary(role) ->
        [%{"role" => anthropic_role(role), "content" => anthropic_content(content)}]

      %{"type" => "function_call_output", "call_id" => call_id, "output" => output} ->
        [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => to_string(call_id),
                "content" => content_to_text(output)
              }
            ]
          }
        ]

      value ->
        [
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => content_to_text(value)}]
          }
        ]
    end)
  end

  defp anthropic_messages(_input), do: []

  defp anthropic_messages_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> "v1/messages"
      path -> path
    end
  end

  defp anthropic_messages_path(_path), do: "v1/messages"

  defp anthropic_role("assistant"), do: "assistant"
  defp anthropic_role(_role), do: "user"

  defp anthropic_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp anthropic_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => type, "text" => text} when type in ["input_text", "output_text", "text"] ->
        [%{"type" => "text", "text" => to_string(text)}]

      %{"type" => "tool_use"} = part ->
        [Map.take(part, ["type", "id", "name", "input"])]

      %{"type" => "tool_result"} = part ->
        [Map.take(part, ["type", "tool_use_id", "content", "is_error"])]

      value ->
        [%{"type" => "text", "text" => content_to_text(value)}]
    end)
  end

  defp anthropic_content(content), do: [%{"type" => "text", "text" => content_to_text(content)}]

  # Responses/OpenAI tools wrap functions under `%{"type" => "function"}`.
  # Anthropic expects `name`, `description`, and `input_schema` at the tool top
  # level, so only that portable subset is translated here.
  defp anthropic_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"type" => "function", "function" => function} when is_map(function) ->
        [
          %{
            "name" => to_string(Map.get(function, "name")),
            "description" => Map.get(function, "description") || "",
            "input_schema" => Map.get(function, "parameters") || %{"type" => "object"}
          }
        ]

      %{"type" => "function", "name" => name} = tool ->
        [
          %{
            "name" => to_string(name),
            "description" => Map.get(tool, "description") || "",
            "input_schema" => Map.get(tool, "parameters") || %{"type" => "object"}
          }
        ]

      %{"name" => name, "input_schema" => schema} = tool ->
        [
          %{
            "name" => to_string(name),
            "description" => Map.get(tool, "description") || "",
            "input_schema" => schema
          }
        ]

      _tool ->
        []
    end)
  end

  defp anthropic_tools(_tools), do: nil

  defp anthropic_tool_choice(%{"type" => "function", "function" => %{"name" => name}}),
    do: %{"type" => "tool", "name" => name}

  defp anthropic_tool_choice(%{"type" => "tool", "name" => _name} = choice), do: choice
  defp anthropic_tool_choice("auto"), do: %{"type" => "auto"}
  defp anthropic_tool_choice("none"), do: %{"type" => "none"}
  defp anthropic_tool_choice(_choice), do: nil

  # Azure path selection is intentionally URL-family aware. Account-root URLs
  # need an `/openai/...` prefix, `/openai` URLs already include it, and
  # `/openai/v1` URLs use OpenAI-style paths without deployment/api-version.
  defp azure_response_path(runtime, endpoint_mode, options) do
    base_url = options |> Map.get("base_url", "") |> to_string()
    api_version = Map.get(options, "api_version") || "2025-04-01-preview"
    deployment = Map.get(options, "deployment") || runtime["model"]

    cond do
      azure_foundry_base_url?(base_url) ->
        {:error, :unsupported_azure_foundry_endpoint}

      azure_v1_base_url?(base_url) and endpoint_mode == "responses" ->
        {:ok, "responses", true}

      azure_v1_base_url?(base_url) and endpoint_mode == "chat_completions" ->
        {:ok, "chat/completions", true}

      endpoint_mode == "responses" ->
        {:ok,
         azure_traditional_path(
           base_url,
           "responses?api-version=#{URI.encode_www_form(api_version)}"
         ), true}

      is_binary(deployment) and deployment != "" ->
        {:ok,
         azure_traditional_path(
           base_url,
           "deployments/#{URI.encode_www_form(deployment)}/chat/completions?api-version=#{URI.encode_www_form(api_version)}"
         ), false}

      true ->
        {:error, :missing_azure_deployment}
    end
  end

  defp azure_traditional_path(base_url, path) do
    if azure_openai_base_url?(base_url) do
      path
    else
      "openai/#{path}"
    end
  end

  defp azure_v1_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) -> String.contains?(path, "/openai/v1")
      _uri -> false
    end
  end

  defp azure_openai_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> Enum.member?("openai")

      _uri ->
        false
    end
  end

  defp azure_foundry_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.ends_with?(host, ".services.ai.azure.com")
      _uri -> false
    end
  end

  defp maybe_delete_model(body, true), do: body
  defp maybe_delete_model(body, false), do: Map.delete(body, "model")

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => type, "text" => text} when type in ["input_text", "output_text", "text"] ->
        to_string(text)

      %{"text" => text} ->
        to_string(text)

      value ->
        inspect(value)
    end)
    |> Enum.join("\n")
  end

  defp content_to_text(content), do: inspect(content)
end
