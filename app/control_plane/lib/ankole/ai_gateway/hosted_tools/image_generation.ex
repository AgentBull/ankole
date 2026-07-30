defmodule Ankole.AIGateway.HostedTools.ImageGeneration do
  @moduledoc """
  Public Responses `image_generation` tool validation and private executor spec.

  A provider that declares native image generation receives the public tool in
  its main request. Otherwise this module resolves the separate image provider,
  validates a definitive endpoint, and prepares the private request consumed by
  Kernel HostedResponsesExecutor.
  """

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.HostedTools.ImageGeneration.Error
  alias Ankole.AIGateway.ImageModelCatalog
  alias Ankole.AIGateway.ImageStreamPersistence
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.Logging

  @allowed_fields ~w(
    type action background input_fidelity input_image_mask model moderation
    output_compression output_format partial_images quality size
  )
  @enums %{
    "action" => ~w(generate edit auto),
    "background" => ~w(transparent opaque auto),
    "input_fidelity" => ~w(high low),
    "moderation" => ~w(auto low),
    "output_format" => ~w(png webp jpeg),
    "quality" => ~w(low medium high auto)
  }
  @max_response_bytes 128 * 1024 * 1024

  @spec prepare(String.t(), map(), keyword()) ::
          {:ok, map() | nil} | {:error, OpenAIError.t() | term()}
  def prepare(subject_uid, request, opts \\ []) when is_map(request) do
    with {:ok, declared_image_tool} <- declared_tool(request) do
      case declared_image_tool do
        nil ->
          with :ok <- reject_undeclared_image_tool_choice(request), do: {:ok, nil}

        {tool, tool_index} ->
          with :ok <- validate_tool_choice(request, declared_image_tool) do
            prepare_declared_tool(subject_uid, request, tool, tool_index, opts)
          end
      end
    end
  end

  @spec persist_response(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate persist_response(subject_uid, response, opts \\ []), to: ImageStreamPersistence

  @spec normalize_persistence_error(term()) :: OpenAIError.t()
  defdelegate normalize_persistence_error(reason), to: Error, as: :normalize_persistence

  @spec normalize_execution_error(term()) :: OpenAIError.t()
  defdelegate normalize_execution_error(reason), to: Error, as: :normalize_execution

  @doc false
  @spec pop_credential_attempt(map()) :: {map() | nil, map()}
  def pop_credential_attempt(spec) when is_map(spec),
    do: Map.pop(spec, :hosted_credential_attempt)

  @doc false
  @spec record_credential_failure(map() | nil, term()) :: :ok
  def record_credential_failure(%{context: context}, reason) when is_map(context),
    do: CredentialAttempts.record_failure(context, reason)

  def record_credential_failure(_attempt, _reason), do: :ok

  @doc false
  @spec credential_failure?(term()) :: boolean()
  def credential_failure?(reason), do: failure_stage(reason) == "image_generation"

  @doc false
  @spec hosted_execution_failure?(term()) :: boolean()
  def hosted_execution_failure?(reason), do: failure_stage(reason) == "hosted_responses"

  @doc false
  @spec record_credential_usage(map() | nil, map()) :: :ok
  def record_credential_usage(%{context: context}, response_or_event)
      when is_map(context) and is_map(response_or_event) do
    case hosted_image_usage(response_or_event) do
      %{} = usage ->
        CredentialAttempts.record_usage(context, %{
          "tool_usage" => %{"image_gen" => usage}
        })

      _missing ->
        :ok
    end
  end

  def record_credential_usage(_attempt, _response_or_event), do: :ok

  defp prepare_declared_tool(subject_uid, request, tool, tool_index, opts) do
    param_prefix = "tools[#{tool_index}]"
    catalog_opts = Keyword.put(opts, :tool_index, tool_index)

    with :ok <- validate_tool(tool, param_prefix) do
      case Resolver.resolve_request_model(subject_uid, "image_generate", %{
             "model" => "image_generate.default"
           }) do
        {:ok, runtime} ->
          prepare_hosted_tool(
            subject_uid,
            request,
            tool,
            tool_index,
            param_prefix,
            runtime,
            catalog_opts,
            opts
          )

        {:error, :model_profile_not_configured} ->
          prepare_native_tool(tool_index, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp prepare_hosted_tool(
         subject_uid,
         request,
         tool,
         tool_index,
         param_prefix,
         runtime,
         catalog_opts,
         opts
       ) do
    with {:ok, references} <- Artifacts.resolve_references(subject_uid, request),
         input_references = Enum.reject(references, &mask_reference?/1),
         :ok <- validate_action_references(tool, input_references, param_prefix),
         requested_model = Map.get(tool, "model", runtime["model"]),
         {:ok, selection} <-
           ImageModelCatalog.select_endpoint(
             runtime,
             requested_model,
             tool,
             length(input_references),
             catalog_opts
           ),
         :ok <-
           log_routing(subject_uid, request, tool, tool_index, references, selection, opts),
         runtime = Map.put(runtime, "model", selection.model),
         image_request = image_request(tool, references, selection, opts),
         {:ok, prepared_request} <-
           Providers.build_image_generate_request(runtime, image_request,
             stream?: image_request["stream"]
           ),
         {credential_attempt, prepared_request} <- CredentialAttempts.pop(prepared_request),
         prepared_request <-
           Map.update(
             prepared_request,
             :limits,
             %{max_response_bytes: @max_response_bytes},
             &Map.put(&1, :max_response_bytes, @max_response_bytes)
           ) do
      {:ok,
       %{
         "tool_config" => tool,
         "actor_event_id" => get_in(request, ["metadata", "actor_event_id"]),
         "selected_model" => selection.model,
         "prepared_request" => prepared_request,
         "endpoint_capabilities" => selection.endpoint,
         "provider_tag" => selection.provider_tag,
         "provider_tags" => selection.provider_tags,
         "provider_slug" => selection.provider_slug,
         "provider_slugs" => selection.provider_slugs,
         "resolved_references" => references,
         "limits" => %{
           "max_decoded_image_bytes" => Artifacts.max_image_bytes(),
           "max_reference_bytes" => 100 * 1024 * 1024,
           "max_response_bytes" => @max_response_bytes
         },
         credential_attempt: credential_attempt
       }}
    end
  end

  defp hosted_image_usage(%{body: %{} = body}), do: hosted_image_usage(body)
  defp hosted_image_usage(%{"body" => %{} = body}), do: hosted_image_usage(body)
  defp hosted_image_usage(%{"response" => %{} = response}), do: hosted_image_usage(response)

  defp hosted_image_usage(%{"tool_usage" => %{"image_gen" => %{} = usage}}),
    do: usage

  defp hosted_image_usage(_response_or_event), do: nil

  defp failure_stage({:universal_ai_request_failed, %{} = error}),
    do: Map.get(error, "stage") || Map.get(error, :stage)

  defp failure_stage(%{} = error),
    do: Map.get(error, "stage") || Map.get(error, :stage)

  defp failure_stage(_reason), do: nil

  defp prepare_native_tool(tool_index, opts) do
    if Providers.supports_native_image_generation?(Keyword.get(opts, :main_runtime)) do
      {:ok, nil}
    else
      {:error,
       OpenAIError.invalid(
         "tools[#{tool_index}].type",
         "unsupported_value",
         "image_generation requires either an image_generate model profile or a language-model provider that supports native image generation."
       )}
    end
  end

  defp declared_tool(request) do
    tools = Map.get(request, "tools", [])

    cond do
      is_nil(tools) ->
        {:ok, nil}

      not is_list(tools) ->
        {:error, OpenAIError.invalid("tools", "invalid_type", "tools must be an array.")}

      true ->
        image_tools =
          tools
          |> Enum.with_index()
          |> Enum.filter(fn {tool, _index} ->
            is_map(tool) and Map.get(tool, "type") == "image_generation"
          end)

        case image_tools do
          [] ->
            {:ok, nil}

          [{tool, index}] ->
            {:ok, {tool, index}}

          _tools ->
            {:error,
             OpenAIError.invalid(
               "tools",
               "invalid_value",
               "Only one image_generation tool may be declared."
             )}
        end
    end
  end

  defp validate_tool(tool, param_prefix) do
    with :ok <- reject_unknown_fields(tool, param_prefix),
         :ok <- validate_enums(tool, param_prefix),
         :ok <- validate_optional_integer(tool, "output_compression", 0..100, param_prefix),
         :ok <- validate_output_compression_format(tool, param_prefix),
         :ok <- validate_optional_integer(tool, "partial_images", 0..3, param_prefix),
         :ok <- validate_optional_model(tool, param_prefix),
         :ok <- validate_optional_size(tool, param_prefix),
         :ok <- validate_optional_mask(tool, param_prefix) do
      :ok
    end
  end

  defp reject_unknown_fields(tool, param_prefix) do
    case Map.keys(tool) -- @allowed_fields do
      [] ->
        :ok

      [field | _rest] ->
        {:error,
         OpenAIError.invalid(
           "#{param_prefix}.#{field}",
           "unknown_parameter",
           "Unknown parameter: #{param_prefix}.#{field}."
         )}
    end
  end

  defp validate_enums(tool, param_prefix) do
    Enum.reduce_while(@enums, :ok, fn {field, allowed}, :ok ->
      case Map.fetch(tool, field) do
        :error ->
          {:cont, :ok}

        {:ok, nil} when field == "input_fidelity" ->
          {:cont, :ok}

        {:ok, value} ->
          if value in allowed do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              OpenAIError.invalid(
                "#{param_prefix}.#{field}",
                "unsupported_value",
                "Unsupported value: #{inspect(value)}."
              )}}
          end
      end
    end)
  end

  defp validate_optional_integer(tool, field, range, param_prefix) do
    case Map.fetch(tool, field) do
      :error ->
        :ok

      {:ok, value} ->
        if is_integer(value) and value >= range.first and value <= range.last do
          :ok
        else
          {:error,
           OpenAIError.invalid(
             "#{param_prefix}.#{field}",
             "invalid_value",
             "#{field} must be an integer from #{range.first} to #{range.last}."
           )}
        end
    end
  end

  defp validate_output_compression_format(
         %{"output_compression" => _compression, "output_format" => format},
         _param_prefix
       )
       when format in ["jpeg", "webp"],
       do: :ok

  defp validate_output_compression_format(
         %{"output_compression" => _compression},
         param_prefix
       ) do
    {:error,
     OpenAIError.invalid(
       "#{param_prefix}.output_compression",
       "invalid_value",
       "output_compression requires output_format to be 'jpeg' or 'webp'."
     )}
  end

  defp validate_output_compression_format(_tool, _param_prefix), do: :ok

  defp validate_optional_model(tool, param_prefix) do
    case Map.fetch(tool, "model") do
      :error ->
        :ok

      {:ok, model} ->
        if is_binary(model) and String.trim(model) != "" do
          :ok
        else
          {:error,
           OpenAIError.invalid(
             "#{param_prefix}.model",
             "invalid_type",
             "model must be a string."
           )}
        end
    end
  end

  defp validate_optional_size(tool, param_prefix) do
    case Map.fetch(tool, "size") do
      :error ->
        :ok

      {:ok, "auto"} ->
        :ok

      {:ok, value} when is_binary(value) ->
        case Regex.run(~r/\A([1-9]\d*)x([1-9]\d*)\z/, value) do
          [_match, _width, _height] -> :ok
          _invalid -> invalid_size(param_prefix)
        end

      {:ok, _value} ->
        invalid_size(param_prefix)
    end
  end

  defp invalid_size(param_prefix) do
    {:error,
     OpenAIError.invalid(
       "#{param_prefix}.size",
       "invalid_value",
       "size must be 'auto' or WIDTHxHEIGHT."
     )}
  end

  defp validate_optional_mask(tool, param_prefix) do
    case Map.fetch(tool, "input_image_mask") do
      :error ->
        :ok

      {:ok, %{} = mask} ->
        unknown = Map.keys(mask) -- ~w(file_id image_url)

        cond do
          unknown != [] ->
            {:error,
             OpenAIError.invalid(
               "#{param_prefix}.input_image_mask.#{hd(unknown)}",
               "unknown_parameter",
               "Unknown mask parameter."
             )}

          Enum.all?(Map.values(mask), &is_binary/1) ->
            :ok

          true ->
            {:error,
             OpenAIError.invalid(
               "#{param_prefix}.input_image_mask",
               "invalid_type",
               "Mask references must be strings."
             )}
        end

      {:ok, _mask} ->
        {:error,
         OpenAIError.invalid(
           "#{param_prefix}.input_image_mask",
           "invalid_type",
           "input_image_mask must be an object."
         )}
    end
  end

  defp validate_tool_choice(request, image_tool) do
    case Map.get(request, "tool_choice", "auto") do
      choice when choice in ["none", "auto", "required"] ->
        :ok

      %{"type" => "image_generation"} when not is_nil(image_tool) ->
        :ok

      %{"type" => "image_generation"} ->
        missing_image_tool_choice()

      %{"type" => "function", "name" => name} when is_binary(name) ->
        :ok

      %{"type" => "allowed_tools", "mode" => mode, "tools" => tools}
      when mode in ["auto", "required"] and is_list(tools) ->
        if Enum.any?(tools, &(is_map(&1) and Map.get(&1, "type") == "image_generation")) and
             is_nil(image_tool) do
          missing_image_tool_choice()
        else
          :ok
        end

      _choice ->
        {:error,
         OpenAIError.invalid(
           "tool_choice",
           "invalid_value",
           "Invalid tool_choice for this Responses request."
         )}
    end
  end

  defp reject_undeclared_image_tool_choice(request) do
    case Map.get(request, "tool_choice", "auto") do
      %{"type" => "image_generation"} ->
        missing_image_tool_choice()

      %{"type" => "allowed_tools", "tools" => tools} when is_list(tools) ->
        if Enum.any?(tools, &(is_map(&1) and Map.get(&1, "type") == "image_generation")) do
          missing_image_tool_choice()
        else
          :ok
        end

      _other_choice ->
        :ok
    end
  end

  defp missing_image_tool_choice do
    {:error,
     OpenAIError.invalid(
       "tool_choice",
       "invalid_value",
       "tool_choice references an undeclared image_generation tool."
     )}
  end

  defp image_request(tool, references, selection, opts) do
    partial_images = Map.get(tool, "partial_images", 0)
    stream? = Keyword.get(opts, :stream?, false) and partial_images > 0

    %{
      "model" => selection.model,
      "prompt" => "",
      "n" => 1,
      "stream" => stream?,
      "input_references" =>
        references
        |> Enum.reject(&mask_reference?/1)
        |> Enum.map(&upstream_reference/1),
      "provider" => provider_routing(tool, selection)
    }
    |> copy_if_present(
      tool,
      ~w(quality background output_compression output_format size input_fidelity)
    )
    |> put_resolved_mask(tool, references)
  end

  defp put_resolved_mask(request, %{"input_image_mask" => %{} = mask}, references) do
    file_id = Map.get(mask, "file_id")

    case Enum.find(references, fn reference ->
           id = Map.get(reference, "id")

           (is_binary(file_id) and id == file_id) or
             (is_nil(file_id) and is_binary(id) and
                String.ends_with?(id, "].input_image_mask"))
         end) do
      %{"image_url" => image_url} ->
        Map.put(request, "input_image_mask", %{"image_url" => image_url})

      _missing ->
        request
    end
  end

  defp put_resolved_mask(request, _tool, _references), do: request

  defp validate_action_references(%{"action" => "edit"}, [], param_prefix) do
    {:error,
     OpenAIError.invalid(
       "#{param_prefix}.action",
       "invalid_value",
       "action 'edit' requires at least one input image."
     )}
  end

  defp validate_action_references(_tool, _references, _param_prefix), do: :ok

  defp upstream_reference(%{"image_url" => url}) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp mask_reference?(%{"mask" => true}), do: true

  defp mask_reference?(%{"id" => id}) when is_binary(id),
    do: String.match?(id, ~r/^tools\[\d+\]\.input_image_mask$/)

  defp mask_reference?(_reference), do: false

  defp provider_routing(tool, selection) do
    %{
      "only" => selection.provider_tags,
      "allow_fallbacks" => true,
      "require_parameters" => true
    }
    |> maybe_put_moderation(tool, selection.provider_slugs)
  end

  defp maybe_put_moderation(provider, %{"moderation" => moderation}, provider_slugs)
       when is_binary(moderation) do
    options = Map.new(provider_slugs, &{&1, %{"moderation" => moderation}})
    Map.put(provider, "options", options)
  end

  defp maybe_put_moderation(provider, _tool, _provider_slugs), do: provider

  defp log_routing(subject_uid, request, tool, tool_index, references, selection, opts) do
    Logging.info(
      "ai_gateway.image_generation_route_selected",
      "AIGateway image generation route selected",
      %{
        subject_uid: subject_uid,
        actor_event_id: get_in(request, ["metadata", "actor_event_id"]),
        tool_index: tool_index,
        model: selection.model,
        provider_tags: selection.provider_tags,
        provider_slugs: selection.provider_slugs,
        candidate_count: length(selection.provider_tags),
        allow_fallbacks: true,
        action: Map.get(tool, "action", "auto"),
        reference_count: Enum.count(references, &(not mask_reference?(&1))),
        partial_images: Map.get(tool, "partial_images", 0),
        stream: Keyword.get(opts, :stream?, false)
      }
    )
  end

  defp copy_if_present(target, source, fields) do
    Enum.reduce(fields, target, fn field, acc ->
      case Map.fetch(source, field) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end
end
