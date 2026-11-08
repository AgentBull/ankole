defmodule Ankole.AIGateway.ImageRequests do
  @moduledoc """
  Direct and native-Responses image generation requests through AIGateway.
  """

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ProviderFailure
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestExecution
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.Attrs

  @spec create_image(
          String.t(),
          map(),
          keyword(),
          (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def create_image(subject_uid, request, opts, create_response_fun)
      when is_map(request) and is_function(create_response_fun, 3) do
    request = Attrs.normalize_external_attrs(request)

    with :ok <- reject_unknown_fields(request),
         {:ok, prompt} <- validate_prompt(request),
         {:ok, images} <- validate_inputs(request),
         {:ok, mask} <- validate_mask(request),
         tool = ImageGeneration.build_direct_tool(request, mask),
         :ok <- ImageGeneration.validate_direct_tool(tool, images),
         {:ok, hosted_caps} <- ModelProfiles.provider_hosted_capabilities(subject_uid) do
      content_items =
        [%{"type" => "input_text", "text" => prompt}] ++
          Enum.map(images, &%{"type" => "input_image", "image_url" => &1})

      if Map.get(hosted_caps, "image_generate", true) do
        execute_native(subject_uid, tool, content_items, opts, create_response_fun)
      else
        execute_direct(subject_uid, prompt, tool, content_items, opts)
      end
    end
  end

  def create_image(_subject_uid, _request, _opts, _create_response_fun),
    do: {:error, :invalid_request_body}

  defp execute_native(subject_uid, tool, content_items, opts, create_response_fun) do
    with {:ok, primary_runtime} <-
           Resolver.resolve_request_model(subject_uid, "llm", %{"model" => "primary"}) do
      if Providers.supports_native_image_generation?(primary_runtime) do
        responses_request = %{
          "model" => "primary",
          "store" => false,
          "input" => [%{"type" => "message", "role" => "user", "content" => content_items}],
          "tools" => [tool],
          "tool_choice" => %{"type" => "image_generation"}
        }

        with {:ok, response} <-
               create_response_fun.(
                 subject_uid,
                 responses_request,
                 Keyword.put(opts, :persist_artifacts?, false)
               ),
             {:ok, image_body} <- normalize_native_body(response.body) do
          {:ok, %{response | body: image_body}}
        end
      else
        {:error, :model_profile_not_configured}
      end
    end
  end

  defp execute_direct(subject_uid, prompt, tool, content_items, opts) do
    with :ok <- ResponsesPreparation.ensure_token_quota(subject_uid, opts),
         {:ok, runtime} <-
           Resolver.resolve_request_model(subject_uid, "image_generate", %{
             "model" => "image_generate.default"
           }),
         {:ok, selected_runtime, prepared_request} <-
           ImageGeneration.prepare_direct_request(
             subject_uid,
             runtime,
             prompt,
             tool,
             content_items
           ),
         {:ok, upstream_response} <-
           execute_direct_upstream(selected_runtime, prepared_request, opts),
         {:ok, image_body} <- normalize_direct_body(Map.fetch!(upstream_response, :body)) do
      {:ok, RequestExecution.gateway_response(200, image_body, selected_runtime)}
    end
  end

  defp execute_direct_upstream(selected_runtime, prepared_request, opts) do
    case RequestExecution.execute_prepared_request(selected_runtime, prepared_request, opts) do
      {:ok, _upstream_response} = ok ->
        ok

      {:error, %ProviderFailure{} = failure} ->
        {:error, ImageGeneration.normalize_execution_error(failure)}

      {:error, _reason} = error ->
        error
    end
  end

  defp reject_unknown_fields(request) do
    allowed_fields = ["prompt", "images", "mask" | ImageGeneration.direct_tool_fields()]

    case Map.keys(request) -- allowed_fields do
      [] ->
        :ok

      [field | _rest] ->
        {:error,
         OpenAIError.invalid(
           field,
           "unknown_parameter",
           "Unknown parameter: #{field}."
         )}
    end
  end

  defp validate_prompt(request) do
    case Map.get(request, "prompt") do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "" do
          {:error, OpenAIError.invalid("prompt", "invalid_value", "prompt must not be empty.")}
        else
          {:ok, prompt}
        end

      _other ->
        {:error,
         OpenAIError.invalid("prompt", "missing_required_parameter", "prompt is required.")}
    end
  end

  defp validate_inputs(request) do
    case Map.get(request, "images") do
      nil ->
        {:ok, []}

      images when is_list(images) ->
        if Enum.all?(images, &non_empty_string?/1) do
          {:ok, images}
        else
          {:error,
           OpenAIError.invalid(
             "images",
             "invalid_type",
             "images must be an array of non-empty strings."
           )}
        end

      _other ->
        {:error, OpenAIError.invalid("images", "invalid_type", "images must be an array.")}
    end
  end

  defp validate_mask(request) do
    case Map.get(request, "mask") do
      nil ->
        {:ok, nil}

      mask when is_binary(mask) ->
        if String.trim(mask) == "" do
          {:error, OpenAIError.invalid("mask", "invalid_value", "mask must not be empty.")}
        else
          {:ok, mask}
        end

      _other ->
        {:error, OpenAIError.invalid("mask", "invalid_type", "mask must be a string.")}
    end
  end

  defp normalize_native_body(%{"status" => "completed", "output" => output} = body)
       when is_list(output) do
    case Enum.find(output, fn item ->
           is_map(item) and item["type"] == "image_generation_call" and
             item["status"] == "completed" and is_binary(item["result"])
         end) do
      %{"result" => base64} = item ->
        build_generated_image_body(
          base64,
          item["mime_type"],
          item["revised_prompt"],
          body["usage"]
        )

      nil ->
        {:error, :missing_generated_image}
    end
  end

  defp normalize_native_body(body) when is_map(body) do
    {:error,
     {:incomplete_response, Map.take(body, ["status", "incomplete_details", "error", "usage"])}}
  end

  defp normalize_direct_body(%{"result" => base64} = body) when is_binary(base64) do
    build_generated_image_body(
      base64,
      body["mime_type"],
      body["revised_prompt"],
      body["usage"]
    )
  end

  defp normalize_direct_body(_body), do: {:error, :missing_generated_image}

  defp build_generated_image_body(base64, declared_mime_type, revised_prompt, usage) do
    with {:ok, %{payload: payload, mime_type: mime_type}} <-
           Artifacts.validate_generated_image(base64, declared_mime_type) do
      {:ok,
       %{
         "b64_json" => base64,
         "bytes" => payload,
         "mime_type" => mime_type,
         "revised_prompt" => revised_prompt,
         "usage" => usage || %{}
       }}
    end
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false
end
