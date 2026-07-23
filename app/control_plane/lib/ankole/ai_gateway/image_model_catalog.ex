defmodule Ankole.AIGateway.ImageModelCatalog do
  @moduledoc """
  Definitive OpenRouter image-model and endpoint capability catalog.

  This catalog is deliberately separate from language-model metadata. Image
  requests are rejected when no fresh or stale definitive endpoint can satisfy
  every requested public field.
  """

  alias Ankole.AIGateway.ModelMetadata.Cache
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderRuntime
  alias Ankole.AIGateway.Providers.OpenRouter
  alias Ankole.AIGateway.UniversalAIRequest

  @default_cache_ttl_ms :timer.hours(1)
  @endpoint_fields [
    {"quality", "quality"},
    {"background", "background"},
    {"output_compression", "output_compression"},
    {"output_format", "output_format"},
    {"size", "size"},
    {"input_fidelity", "input_fidelity"},
    {"input_image_mask", "input_image_mask"}
  ]

  @type selection :: %{
          required(:model) => String.t(),
          required(:endpoint) => map(),
          required(:provider_tag) => String.t(),
          required(:provider_tags) => [String.t()],
          required(:provider_slug) => String.t(),
          required(:provider_slugs) => [String.t()],
          required(:supports_streaming) => boolean()
        }

  @type configuration_error :: :image_model_unavailable | :image_model_catalog_unavailable

  @spec select_endpoint(map(), String.t(), map(), non_neg_integer(), keyword()) ::
          {:ok, selection()} | {:error, OpenAIError.t()}
  def select_endpoint(runtime, requested_model, tool, reference_count, opts \\ []) do
    with :ok <- require_openrouter(runtime, opts),
         {:ok, model} <- normalize_model(requested_model, opts),
         {:ok, source} <- source(runtime, opts),
         {:ok, models} <- cached_models(runtime, source, opts),
         {:ok, _model_record} <- exact_model(models, model, opts),
         {:ok, endpoints} <- cached_endpoints(runtime, source, model, opts),
         {:ok, matching_endpoints} <-
           satisfying_endpoints(endpoints, tool, reference_count, opts) do
      endpoint = hd(matching_endpoints)

      provider_tags =
        matching_endpoints |> Enum.map(&Map.fetch!(&1, "provider_tag")) |> Enum.uniq()

      provider_slugs =
        matching_endpoints |> Enum.map(&Map.fetch!(&1, "provider_slug")) |> Enum.uniq()

      {:ok,
       %{
         model: model,
         endpoint: endpoint,
         provider_tag: hd(provider_tags),
         provider_tags: provider_tags,
         provider_slug: hd(provider_slugs),
         provider_slugs: provider_slugs,
         supports_streaming: Map.get(endpoint, "supports_streaming") == true
       }}
    end
  end

  @doc """
  Validates that a configured image profile resolves to a definitive endpoint.

  The general OpenRouter model catalog is discovery metadata only. Persisted
  image profiles use the same image-model and endpoint catalogs as runtime
  dispatch, so a model with no usable endpoint is rejected before it becomes
  agent configuration.
  """
  @spec validate_configured_model(Provider.t(), String.t(), keyword()) ::
          :ok | {:error, configuration_error()}
  def validate_configured_model(%Provider{} = provider, requested_model, opts \\ []) do
    runtime = %{
      "provider_id" => provider.provider_id,
      "provider_kind" => provider.provider_kind,
      "provider" => provider,
      "model" => requested_model
    }

    case select_endpoint(runtime, requested_model, %{}, 0, opts) do
      {:ok, _selection} ->
        :ok

      {:error, %OpenAIError{code: code}} when code in ["model_not_found", "unsupported_value"] ->
        {:error, :image_model_unavailable}

      {:error, %OpenAIError{}} ->
        {:error, :image_model_catalog_unavailable}
    end
  end

  @spec normalize_model(String.t()) :: {:ok, String.t()} | {:error, OpenAIError.t()}
  def normalize_model(model), do: normalize_model(model, [])

  defp normalize_model(model, opts) when is_binary(model) do
    case String.trim(model) do
      "" ->
        {:error,
         OpenAIError.invalid(
           tool_param(opts, "model"),
           "invalid_value",
           "Image model must not be empty."
         )}

      model ->
        {:ok, if(String.contains?(model, "/"), do: model, else: "openai/#{model}")}
    end
  end

  defp normalize_model(_model, opts) do
    {:error,
     OpenAIError.invalid(
       tool_param(opts, "model"),
       "invalid_type",
       "Image model must be a string."
     )}
  end

  defp require_openrouter(%{"provider_kind" => "openrouter"}, _opts), do: :ok

  defp require_openrouter(_runtime, opts) do
    {:error,
     OpenAIError.invalid(
       tool_param(opts, "model"),
       "unsupported_value",
       "The configured image_generate provider does not support image generation."
     )}
  end

  defp source(%{"provider" => %Provider{} = provider}, opts) do
    with {:ok, ctx} <-
           ProviderRuntime.context(provider, Keyword.put(opts, :capability, "image_generate")),
         {:ok, source} <- OpenRouter.image_models_metadata_source(ctx) do
      {:ok, source}
    else
      _reason -> catalog_fetch_error(:upstream, opts)
    end
  end

  defp source(_runtime, opts), do: catalog_unavailable(opts)

  defp cached_models(runtime, source, opts) do
    key = {:image_model_catalog, runtime["provider_id"], source.cache_key}

    cached_fetch(key, opts, fn ->
      fetch_list(source, source.models_path, &model_list/1)
    end)
  end

  defp cached_endpoints(runtime, source, model, opts) do
    path = endpoint_path(model)
    key = {:image_model_endpoints, runtime["provider_id"], path}

    cached_fetch(key, opts, fn ->
      fetch_list(source, path, &endpoint_list/1)
    end)
  end

  defp cached_fetch(key, opts, fetch_fun) do
    lookup = if Keyword.get(opts, :force_refresh, false), do: :miss, else: Cache.lookup(key)

    case lookup do
      {:fresh, value} ->
        {:ok, value}

      stale_or_miss ->
        case fetch_fun.() do
          {:ok, value} ->
            :ok = Cache.put(key, value, Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms))
            {:ok, value}

          {:error, reason} ->
            case stale_or_miss do
              {:stale, value} -> {:ok, value}
              :miss -> catalog_fetch_error(reason, opts)
            end
        end
    end
  end

  defp fetch_list(source, path, body_mapper) do
    case UniversalAIRequest.raw_get(source.ctx, path, headers: source.headers) do
      {:ok, %{"status" => status, "body" => body}} when status in 200..299 ->
        case body_mapper.(stringify_keys(body)) do
          values when is_list(values) -> {:ok, Enum.map(values, &stringify_keys/1)}
          _body -> {:error, :image_model_catalog_unavailable}
        end

      {:ok, %{"status" => status}} when is_integer(status) ->
        {:error, classify_catalog_status(status)}

      {:error, reason} ->
        {:error, classify_catalog_error(reason)}

      _response ->
        {:error, :image_model_catalog_unavailable}
    end
  end

  defp classify_catalog_status(429), do: :rate_limited
  defp classify_catalog_status(status) when status in [408, 504], do: :timeout

  defp classify_catalog_status(status) when status in [401, 403] or status in 500..599,
    do: :upstream

  defp classify_catalog_status(_status), do: :image_model_catalog_unavailable

  defp classify_catalog_error(%{"provider_status" => status}) when is_integer(status),
    do: classify_catalog_status(status)

  defp classify_catalog_error(%{"code" => code})
       when code in ["first_byte_timeout", "idle_timeout", "total_timeout"],
       do: :timeout

  defp classify_catalog_error(_reason), do: :upstream

  defp model_list(%{"data" => models}) when is_list(models), do: models
  defp model_list(models) when is_list(models), do: models
  defp model_list(_body), do: nil

  defp endpoint_list(%{"endpoints" => endpoints}) when is_list(endpoints), do: endpoints
  defp endpoint_list(%{"data" => endpoints}) when is_list(endpoints), do: endpoints
  defp endpoint_list(endpoints) when is_list(endpoints), do: endpoints
  defp endpoint_list(_body), do: nil

  defp exact_model(models, model, opts) do
    case Enum.find(models, &(Map.get(&1, "id") == model)) do
      %{} = record ->
        {:ok, record}

      nil ->
        {:error,
         OpenAIError.invalid(
           tool_param(opts, "model"),
           "model_not_found",
           "The requested image model does not exist."
         )}
    end
  end

  defp satisfying_endpoints(endpoints, tool, reference_count, opts) do
    outer_stream? = Keyword.get(opts, :stream?, false)
    partial_images = Map.get(tool, "partial_images", 0)

    matching_endpoints =
      Enum.filter(endpoints, fn endpoint ->
        endpoint_satisfies?(endpoint, tool, reference_count, outer_stream?, partial_images)
      end)

    case matching_endpoints do
      [] -> endpoint_error(endpoints, tool, reference_count, outer_stream?, partial_images, opts)
      [_endpoint | _rest] -> {:ok, matching_endpoints}
    end
  end

  defp endpoint_satisfies?(endpoint, tool, reference_count, outer_stream?, partial_images) do
    supported = Map.get(endpoint, "supported_parameters", %{})

    provider_tag_present?(endpoint) and provider_slug_present?(endpoint) and
      requested_fields_supported?(supported, tool) and
      references_supported?(supported, reference_count) and
      moderation_supported?(endpoint, tool) and
      partials_supported?(endpoint, outer_stream?, partial_images)
  end

  defp requested_fields_supported?(supported, tool) when is_map(supported) do
    Enum.all?(@endpoint_fields, fn {public_field, upstream_field} ->
      case Map.fetch(tool, public_field) do
        :error -> true
        {:ok, nil} -> true
        {:ok, value} -> descriptor_accepts?(Map.get(supported, upstream_field), value)
      end
    end)
  end

  defp requested_fields_supported?(_supported, tool) do
    Enum.all?(@endpoint_fields, fn {field, _upstream} -> is_nil(Map.get(tool, field)) end)
  end

  defp references_supported?(_supported, 0), do: true

  defp references_supported?(supported, count) when is_map(supported) do
    descriptor_accepts?(Map.get(supported, "input_references"), count)
  end

  defp references_supported?(_supported, _count), do: false

  defp moderation_supported?(_endpoint, tool) when not is_map_key(tool, "moderation"), do: true
  defp moderation_supported?(_endpoint, %{"moderation" => nil}), do: true

  defp moderation_supported?(endpoint, _tool) do
    "moderation" in List.wrap(Map.get(endpoint, "allowed_passthrough_parameters"))
  end

  defp partials_supported?(_endpoint, _outer_stream?, 0), do: true

  defp partials_supported?(endpoint, _outer_stream?, partial_images) when partial_images in 1..3,
    do: Map.get(endpoint, "supports_streaming") == true

  defp partials_supported?(_endpoint, _outer_stream?, _partial_images), do: false

  defp descriptor_accepts?(nil, _value), do: false

  defp descriptor_accepts?(%{"type" => "enum", "values" => values}, value),
    do: value in List.wrap(values)

  defp descriptor_accepts?(%{"type" => "range"} = descriptor, value)
       when is_integer(value) do
    min = Map.get(descriptor, "min")
    max = Map.get(descriptor, "max")
    (is_nil(min) or value >= min) and (is_nil(max) or value <= max)
  end

  defp descriptor_accepts?(%{"type" => "boolean"}, _value), do: true

  defp descriptor_accepts?(_descriptor, _value), do: false

  defp endpoint_error(endpoints, tool, reference_count, outer_stream?, partial_images, opts) do
    field = unsupported_field(endpoints, tool, reference_count, outer_stream?, partial_images)

    {:error,
     OpenAIError.invalid(
       tool_param(opts, field),
       "unsupported_value",
       "Unsupported value for this image model."
     )}
  end

  defp unsupported_field(endpoints, tool, reference_count, outer_stream?, partial_images) do
    cond do
      partial_images > 0 and
          not Enum.any?(endpoints, &partials_supported?(&1, outer_stream?, partial_images)) ->
        "partial_images"

      reference_count > 0 and
          not Enum.any?(endpoints, fn endpoint ->
            references_supported?(Map.get(endpoint, "supported_parameters", %{}), reference_count)
          end) ->
        "input"

      Map.has_key?(tool, "moderation") and
          not Enum.any?(endpoints, &moderation_supported?(&1, tool)) ->
        "moderation"

      true ->
        Enum.find_value(@endpoint_fields, "model", fn {public_field, upstream_field} ->
          value = Map.get(tool, public_field)

          if not is_nil(value) and
               not Enum.any?(endpoints, fn endpoint ->
                 descriptor_accepts?(
                   get_in(endpoint, ["supported_parameters", upstream_field]),
                   value
                 )
               end) do
            public_field
          end
        end)
    end
  end

  defp provider_tag_present?(endpoint),
    do: is_binary(Map.get(endpoint, "provider_tag")) and Map.get(endpoint, "provider_tag") != ""

  defp provider_slug_present?(endpoint),
    do: is_binary(Map.get(endpoint, "provider_slug")) and Map.get(endpoint, "provider_slug") != ""

  defp endpoint_path(model) do
    [author, slug] = String.split(model, "/", parts: 2)

    "images/models/#{URI.encode(author, &URI.char_unreserved?/1)}/#{URI.encode(slug, &URI.char_unreserved?/1)}/endpoints"
  end

  defp catalog_unavailable(opts) do
    {:error,
     OpenAIError.invalid(
       tool_param(opts, "model"),
       "image_model_catalog_unavailable",
       "Image model capabilities are temporarily unavailable."
     )}
  end

  defp catalog_fetch_error(:rate_limited, _opts) do
    {:error,
     OpenAIError.server(
       429,
       "rate_limit_exceeded",
       "The image generation provider rate limit was exceeded.",
       "rate_limit_error"
     )}
  end

  defp catalog_fetch_error(:timeout, _opts) do
    {:error,
     OpenAIError.server(504, "upstream_timeout", "The image generation provider timed out.")}
  end

  defp catalog_fetch_error(:upstream, _opts) do
    {:error, OpenAIError.server(502, "upstream_error", "The image model catalog request failed.")}
  end

  defp catalog_fetch_error(_reason, opts), do: catalog_unavailable(opts)

  defp tool_param(opts, field) do
    "tools[#{Keyword.get(opts, :tool_index, 0)}].#{field}"
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
