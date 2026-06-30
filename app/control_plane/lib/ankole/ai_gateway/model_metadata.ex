defmodule Ankole.AIGateway.ModelMetadata do
  @moduledoc """
  Resolves and normalizes model metadata for the AIGateway catalog.

  Provider modules may expose `models_metadata_source/1` for a richer live
  catalog. Providers without that callback use the packaged `llm_db` snapshot by
  provider-id convention and fall back without failing `/models`.
  """

  alias Ankole.AIGateway.ModelMetadata.Cache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.UniversalAIRequest

  @default_cache_ttl_ms :timer.hours(1)
  @default_timeout_ms 15_000

  @base_supported_parameters ~w(
    temperature top_p max_tokens max_output_tokens response_format tools tool_choice metadata
    reasoning reasoningEffort text textVerbosity
  )
  @embedding_supported_parameters ~w(input dimensions encoding_format)
  @rerank_supported_parameters ~w(query documents top_n)

  @llm_db_provider_equivalents %{
    "azure_openai" => "azure",
    "claude" => "anthropic",
    "gemini" => "google",
    "google_ai_studio_openai" => "google"
  }

  @spec list_provider_model_metadata(Provider.t(), keyword()) :: {:ok, [map()]}
  def list_provider_model_metadata(%Provider{} = provider, opts \\ []) do
    with {:ok, source} <- source_for_provider(provider, opts) do
      list_source_models(provider, source, opts)
    else
      {:error, _reason} -> {:ok, []}
    end
  end

  @spec model_metadata(Provider.t(), String.t(), keyword()) :: {:ok, map()}
  def model_metadata(%Provider{} = provider, model_id, opts \\ []) when is_binary(model_id) do
    with {:ok, source} <- source_for_provider(provider, opts),
         {:ok, metadata} <- source_model(provider, source, model_id, opts) do
      {:ok, metadata}
    else
      {:error, _reason} ->
        {:ok, fallback_model_metadata(model_id, Keyword.get(opts, :capability, "llm"))}
    end
  end

  @spec openrouter_entry(map(), String.t(), String.t()) :: map()
  def openrouter_entry(metadata, selector, canonical_slug)
      when is_map(metadata) and is_binary(selector) and is_binary(canonical_slug) do
    metadata
    |> ensure_openrouter_defaults()
    |> Map.put("id", selector)
    |> Map.put("canonical_slug", canonical_slug)
  end

  defp source_for_provider(%Provider{} = provider, opts) do
    with {:ok, definition} <- Providers.fetch(provider.provider_kind) do
      case function_exported?(definition.module, :models_metadata_source, 1) do
        true ->
          with {:ok, context} <- metadata_source_context(provider, opts) do
            apply(definition.module, :models_metadata_source, [context])
          end

        false ->
          llm_db_source(provider)
      end
    end
  end

  defp fallback_model_metadata(model_id, capability \\ "llm") do
    architecture = fallback_architecture(capability)

    %{
      "id" => model_id,
      "canonical_slug" => model_id,
      "name" => model_id,
      "description" => "Metadata unavailable for #{model_id}.",
      "created" => 0,
      "architecture" => architecture,
      "pricing" => zero_pricing(),
      "context_length" => 0,
      "top_provider" => %{
        "is_moderated" => false,
        "context_length" => 0,
        "max_completion_tokens" => nil
      },
      "supported_parameters" => fallback_supported_parameters(capability),
      "default_parameters" => nil,
      "per_request_limits" => nil,
      "supported_voices" => nil,
      "expiration_date" => nil,
      "knowledge_cutoff" => nil,
      "links" => %{}
    }
  end

  defp llm_db_source(%Provider{} = provider) do
    case llm_db_provider(provider) do
      {:ok, provider_atom} -> {:ok, {:llm_db, provider_atom}}
      :error -> {:ok, :fallback}
    end
  end

  defp llm_db_provider(%Provider{} = provider) do
    provider_index =
      LLMDB.providers()
      |> Map.new(fn llm_db_provider ->
        {Atom.to_string(llm_db_provider.id), llm_db_provider.id}
      end)

    provider
    |> provider_candidate_ids()
    |> Enum.find_value(:error, fn candidate ->
      case Map.fetch(provider_index, candidate) do
        {:ok, provider_atom} -> {:ok, provider_atom}
        :error -> false
      end
    end)
  end

  defp provider_candidate_ids(%Provider{} = provider) do
    [provider.provider_kind, provider.provider_id]
    |> Enum.flat_map(&normalized_provider_candidates/1)
    |> Enum.uniq()
  end

  defp normalized_provider_candidates(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    equivalent = Map.get(@llm_db_provider_equivalents, normalized)

    [normalized, equivalent]
    |> Enum.reject(&is_nil/1)
  end

  defp normalized_provider_candidates(_value), do: []

  defp metadata_source_context(%Provider{} = provider, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, connection} <- ProviderConfigs.runtime_connection(provider) do
      {:ok,
       %{
         provider_id: provider.provider_id,
         provider_kind: provider.provider_kind,
         capability: Keyword.get(opts, :capability, "llm"),
         connection: connection,
         settings: atomize_keys(connection),
         timeout_ms: timeout_ms,
         http_client: Keyword.get(opts, :http_client)
       }}
    end
  end

  defp list_source_models(_provider, {:llm_db, provider_atom}, _opts) do
    models =
      provider_atom
      |> LLMDB.models()
      |> Enum.map(&from_llm_db_model/1)

    {:ok, models}
  end

  defp list_source_models(_provider, :fallback, _opts), do: {:ok, []}

  defp list_source_models(%Provider{} = provider, {:openrouter, source}, opts)
       when is_map(source) do
    key =
      {:model_metadata_source, provider.provider_id, :openrouter, Map.fetch!(source, :cache_key)}

    ttl_ms = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)

    case cached_fetch(key, ttl_ms, Keyword.get(opts, :force_refresh, false), fn ->
           fetch_openrouter_models(source)
         end) do
      {:ok, models} -> {:ok, models}
      {:error, _reason} -> {:ok, []}
    end
  end

  defp list_source_models(_provider, _source, _opts), do: {:ok, []}

  defp source_model(%Provider{}, {:llm_db, provider_atom}, model_id, _opts) do
    case LLMDB.model(provider_atom, model_id) do
      {:ok, model} ->
        {:ok, from_llm_db_model(model)}

      {:error, :not_found} ->
        with [model] <-
               provider_atom
               |> LLMDB.models()
               |> Enum.filter(fn model -> model_id in (model.aliases || []) end)
               |> Enum.take(1) do
          {:ok, from_llm_db_model(model)}
        else
          _models -> {:error, :model_metadata_not_found}
        end
    end
  end

  defp source_model(%Provider{} = provider, {:openrouter, _source} = source, model_id, opts) do
    with {:ok, models} <- list_source_models(provider, source, opts),
         %{} = metadata <- Enum.find(models, &(Map.get(&1, "id") == model_id)) do
      {:ok, metadata}
    else
      _reason -> {:error, :model_metadata_not_found}
    end
  end

  defp source_model(_provider, :fallback, _model_id, _opts),
    do: {:error, :model_metadata_not_found}

  defp source_model(_provider, _source, _model_id, _opts), do: {:error, :model_metadata_not_found}

  defp cached_fetch(key, ttl_ms, force_refresh?, fetch_fun) do
    lookup = if force_refresh?, do: :miss, else: Cache.lookup(key)

    case lookup do
      {:fresh, value} ->
        {:ok, value}

      stale_or_miss ->
        case fetch_fun.() do
          {:ok, value} ->
            :ok = Cache.put(key, value, ttl_ms)
            {:ok, value}

          {:error, _reason} = error ->
            case stale_or_miss do
              {:stale, value} -> {:ok, value}
              :miss -> error
            end
        end
    end
  end

  defp fetch_openrouter_models(%{ctx: ctx, path: path, headers: headers})
       when is_map(ctx) and is_binary(path) and is_list(headers) do
    with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
           UniversalAIRequest.raw_get(ctx, path, headers: headers),
         models when is_list(models) <- openrouter_model_list(body) do
      {:ok, Enum.map(models, &from_openrouter_model/1)}
    else
      {:ok, %{"status" => status, "body" => body}} ->
        {:error, {:provider_model_metadata_failed, status, body}}

      {:error, _reason} = error ->
        error

      _reason ->
        {:error, :invalid_provider_model_metadata}
    end
  end

  defp fetch_openrouter_models(_source), do: {:error, :invalid_provider_model_metadata_source}

  defp openrouter_model_list(%{"data" => models}) when is_list(models), do: models
  defp openrouter_model_list(models) when is_list(models), do: models
  defp openrouter_model_list(_body), do: nil

  defp from_openrouter_model(model) when is_map(model) do
    model = stringify_keys(model)
    id = model_string(model["id"] || model["canonical_slug"] || model["name"] || "unknown")

    base = fallback_model_metadata(id)
    top_provider = stringify_keys(model["top_provider"] || %{})
    context_length = first_integer([model["context_length"], top_provider["context_length"]]) || 0

    max_completion_tokens =
      first_integer([
        top_provider["max_completion_tokens"],
        model["max_completion_tokens"],
        model["max_output_tokens"]
      ])

    architecture =
      normalize_openrouter_architecture(model["architecture"], base["architecture"])

    base
    |> Map.merge(Map.take(model, openrouter_passthrough_keys()))
    |> Map.put("id", id)
    |> Map.put("canonical_slug", model_string(model["canonical_slug"] || id))
    |> Map.put("name", model_string(model["name"] || id))
    |> Map.put("description", model["description"] || base["description"])
    |> Map.put("created", integer_or(model["created"], 0))
    |> Map.put("architecture", architecture)
    |> Map.put("pricing", normalize_pricing(model["pricing"]))
    |> Map.put("context_length", context_length)
    |> Map.put(
      "top_provider",
      top_provider
      |> Map.merge(%{
        "is_moderated" => top_provider["is_moderated"] || false,
        "context_length" => context_length,
        "max_completion_tokens" => max_completion_tokens
      })
    )
    |> Map.put("supported_parameters", list_of_strings(model["supported_parameters"]))
    |> ensure_openrouter_defaults()
  end

  defp from_llm_db_model(%LLMDB.Model{} = model) do
    id = model.id
    context_length = get_integer(model.limits, :context) || get_integer(model.limits, :input) || 0
    max_completion_tokens = get_integer(model.limits, :output)
    architecture = architecture_from_llm_db(model)

    fallback_model_metadata(id)
    |> Map.put("canonical_slug", id)
    |> Map.put("name", model.name || id)
    |> Map.put("description", llm_db_description(model))
    |> Map.put("created", llm_db_created(model))
    |> Map.put("architecture", architecture)
    |> Map.put("pricing", pricing_from_llm_db(model))
    |> Map.put("context_length", context_length)
    |> Map.put("top_provider", %{
      "is_moderated" => false,
      "context_length" => context_length,
      "max_completion_tokens" => max_completion_tokens
    })
    |> Map.put("supported_parameters", supported_parameters_from_llm_db(model))
    |> Map.put("knowledge_cutoff", model.knowledge)
    |> Map.put("expiration_date", llm_db_expiration_date(model))
    |> Map.put("links", llm_db_links(model))
    |> ensure_openrouter_defaults()
  end

  defp ensure_openrouter_defaults(metadata) do
    id = model_string(metadata["id"] || "unknown")
    capability = inferred_capability(metadata)
    defaults = fallback_model_metadata(id, capability)

    defaults
    |> Map.merge(metadata)
    |> Map.update!(
      "architecture",
      &normalize_openrouter_architecture(&1, defaults["architecture"])
    )
    |> Map.update!("pricing", &normalize_pricing/1)
    |> Map.update!("supported_parameters", &list_of_strings/1)
    |> Map.update!("context_length", &integer_or(&1, 0))
  end

  defp openrouter_passthrough_keys do
    ~w(
      default_parameters per_request_limits supported_voices expiration_date knowledge_cutoff links
    )
  end

  defp normalize_openrouter_architecture(architecture, fallback) when is_map(architecture) do
    architecture = stringify_keys(architecture)

    input_modalities =
      non_empty_strings(architecture["input_modalities"], fallback["input_modalities"])

    output_modalities =
      non_empty_strings(architecture["output_modalities"], fallback["output_modalities"])

    %{
      "input_modalities" => input_modalities,
      "output_modalities" => output_modalities,
      "modality" => architecture["modality"] || modality(input_modalities, output_modalities),
      "instruct_type" => architecture["instruct_type"],
      "tokenizer" => architecture["tokenizer"]
    }
  end

  defp normalize_openrouter_architecture(_architecture, fallback), do: fallback

  defp architecture_from_llm_db(%LLMDB.Model{} = model) do
    input_modalities =
      model.modalities
      |> get_modalities(:input)
      |> case do
        [] -> inferred_input_modalities(model)
        modalities -> modalities
      end

    output_modalities =
      model.modalities
      |> get_modalities(:output)
      |> case do
        [] -> inferred_output_modalities(model)
        modalities -> modalities
      end

    %{
      "input_modalities" => input_modalities,
      "output_modalities" => output_modalities,
      "modality" => modality(input_modalities, output_modalities),
      "instruct_type" => nil,
      "tokenizer" => nil
    }
  end

  defp inferred_input_modalities(%LLMDB.Model{capabilities: capabilities}) do
    cond do
      truthy_capability?(capabilities, :embeddings) -> ["text"]
      truthy_capability?(capabilities, :rerank) -> ["text"]
      true -> ["text"]
    end
  end

  defp inferred_output_modalities(%LLMDB.Model{capabilities: capabilities}) do
    cond do
      truthy_capability?(capabilities, :embeddings) -> ["embeddings"]
      truthy_capability?(capabilities, :rerank) -> ["text"]
      true -> ["text"]
    end
  end

  defp get_modalities(modalities, key) when is_map(modalities) do
    modalities
    |> Map.get(key, Map.get(modalities, Atom.to_string(key), []))
    |> list_of_strings()
  end

  defp get_modalities(_modalities, _key), do: []

  defp supported_parameters_from_llm_db(%LLMDB.Model{capabilities: capabilities}) do
    []
    |> maybe_add(truthy_capability?(capabilities, :chat), @base_supported_parameters)
    |> maybe_add(truthy_capability?(capabilities, :embeddings), @embedding_supported_parameters)
    |> maybe_add(truthy_capability?(capabilities, :rerank), @rerank_supported_parameters)
    |> maybe_add(tool_capable?(capabilities), ~w(tools tool_choice))
    |> maybe_add(json_capable?(capabilities), ~w(response_format))
    |> maybe_add(reasoning_capable?(capabilities), ~w(reasoning reasoningEffort))
    |> Enum.uniq()
  end

  defp fallback_supported_parameters("embedding"), do: @embedding_supported_parameters
  defp fallback_supported_parameters("rerank"), do: @rerank_supported_parameters
  defp fallback_supported_parameters(_capability), do: @base_supported_parameters

  defp maybe_add(values, true, additions), do: values ++ additions
  defp maybe_add(values, _condition, _additions), do: values

  defp truthy_capability?(capabilities, key) when is_map(capabilities) do
    case Map.get(capabilities, key, Map.get(capabilities, Atom.to_string(key))) do
      false -> false
      nil -> false
      _value -> true
    end
  end

  defp truthy_capability?(_capabilities, _key), do: false

  defp tool_capable?(capabilities) when is_map(capabilities) do
    case Map.get(capabilities, :tools, Map.get(capabilities, "tools")) do
      %{enabled: true} -> true
      %{"enabled" => true} -> true
      true -> true
      _value -> false
    end
  end

  defp tool_capable?(_capabilities), do: false

  defp json_capable?(capabilities) when is_map(capabilities) do
    case Map.get(capabilities, :json, Map.get(capabilities, "json")) do
      json when is_map(json) ->
        Enum.any?([:native, :schema, :strict], &truthy_capability?(json, &1))

      true ->
        true

      _value ->
        false
    end
  end

  defp json_capable?(_capabilities), do: false

  defp reasoning_capable?(capabilities) when is_map(capabilities) do
    case Map.get(capabilities, :reasoning, Map.get(capabilities, "reasoning")) do
      %{enabled: true} -> true
      %{"enabled" => true} -> true
      true -> true
      _value -> false
    end
  end

  defp reasoning_capable?(_capabilities), do: false

  defp pricing_from_llm_db(%LLMDB.Model{} = model) do
    cost = model.cost || %{}

    %{
      "prompt" =>
        price_per_token(get_number(cost, :input) || component_rate(model, "token.input")),
      "completion" =>
        price_per_token(get_number(cost, :output) || component_rate(model, "token.output")),
      "request" =>
        price_per_token(get_number(cost, :request) || component_rate(model, "request")),
      "image" => price_per_token(get_number(cost, :image) || component_rate(model, "image"))
    }
  end

  defp component_rate(%LLMDB.Model{pricing: %{components: components}}, component_id)
       when is_list(components) do
    Enum.find_value(components, fn component ->
      component = stringify_keys(component)

      cond do
        component["id"] == component_id ->
          normalized_component_rate(component)

        component_id == "request" and component["kind"] == "request" ->
          normalized_component_rate(component)

        component_id == "image" and component["kind"] == "image" ->
          normalized_component_rate(component)

        true ->
          nil
      end
    end)
  end

  defp component_rate(_model, _component_id), do: nil

  defp normalized_component_rate(%{"rate" => rate, "per" => per}) when is_number(rate) do
    case per do
      per when is_integer(per) and per > 0 -> rate * 1_000_000 / per
      _per -> rate
    end
  end

  defp normalized_component_rate(_component), do: nil

  defp normalize_pricing(pricing) when is_map(pricing) do
    pricing = stringify_keys(pricing)
    default = zero_pricing()

    %{
      "prompt" => price_string(pricing["prompt"] || default["prompt"]),
      "completion" => price_string(pricing["completion"] || default["completion"]),
      "request" => price_string(pricing["request"] || default["request"]),
      "image" => price_string(pricing["image"] || default["image"])
    }
  end

  defp normalize_pricing(_pricing), do: zero_pricing()

  defp zero_pricing do
    %{
      "prompt" => "0",
      "completion" => "0",
      "request" => "0",
      "image" => "0"
    }
  end

  defp price_per_token(nil), do: "0"
  defp price_per_token(value) when is_number(value), do: price_string(value / 1_000_000)
  defp price_per_token(value), do: price_string(value)

  defp price_string(value) when is_integer(value), do: Integer.to_string(value)

  defp price_string(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 12)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> case do
      "-0" -> "0"
      "" -> "0"
      string -> string
    end
  end

  defp price_string(value) when is_binary(value), do: value
  defp price_string(_value), do: "0"

  defp llm_db_description(%LLMDB.Model{} = model) do
    get_in_map(model.extra, [:description]) || get_in_map(model.extra, ["description"]) ||
      if(model.name, do: model.name, else: "#{model.provider}:#{model.id}")
  end

  defp llm_db_created(%LLMDB.Model{extra: extra, release_date: release_date}) do
    first_integer([get_in_map(extra, [:created]), get_in_map(extra, ["created"])]) ||
      unix_date(release_date) || 0
  end

  defp llm_db_expiration_date(%LLMDB.Model{lifecycle: lifecycle}) do
    get_in_map(lifecycle, [:retires_at]) || get_in_map(lifecycle, ["retires_at"])
  end

  defp llm_db_links(%LLMDB.Model{doc_url: doc_url}) when is_binary(doc_url) and doc_url != "" do
    %{"details" => doc_url}
  end

  defp llm_db_links(_model), do: %{}

  defp unix_date(date) when is_binary(date) do
    with {:ok, date} <- Date.from_iso8601(date) do
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix()
    else
      _reason -> nil
    end
  end

  defp unix_date(_date), do: nil

  defp fallback_architecture("embedding") do
    %{
      "input_modalities" => ["text"],
      "output_modalities" => ["embeddings"],
      "modality" => "text->embeddings",
      "instruct_type" => nil,
      "tokenizer" => nil
    }
  end

  defp fallback_architecture(_capability) do
    %{
      "input_modalities" => ["text"],
      "output_modalities" => ["text"],
      "modality" => "text->text",
      "instruct_type" => nil,
      "tokenizer" => nil
    }
  end

  defp inferred_capability(%{"architecture" => %{"output_modalities" => output_modalities}}) do
    cond do
      "embeddings" in list_of_strings(output_modalities) -> "embedding"
      true -> "llm"
    end
  end

  defp inferred_capability(_metadata), do: "llm"

  defp modality(input_modalities, output_modalities) do
    "#{Enum.join(input_modalities, "+")}->#{Enum.join(output_modalities, "+")}"
  end

  defp non_empty_strings(value, fallback) do
    case list_of_strings(value) do
      [] -> fallback
      values -> values
    end
  end

  defp list_of_strings(values) when is_list(values) do
    values
    |> Enum.map(&model_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_of_strings(_value), do: []

  defp model_string(value) when is_binary(value), do: value
  defp model_string(value) when is_atom(value), do: Atom.to_string(value)
  defp model_string(value) when is_number(value), do: to_string(value)
  defp model_string(_value), do: ""

  defp first_integer(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case integer(value) do
        nil -> false
        integer -> integer
      end
    end)
  end

  defp integer_or(value, default), do: integer(value) || default

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end

  defp integer(_value), do: nil

  defp get_integer(map, key) when is_map(map),
    do: integer(Map.get(map, key, Map.get(map, to_string(key))))

  defp get_integer(_map, _key), do: nil

  defp get_number(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      value when is_number(value) -> value
      _value -> nil
    end
  end

  defp get_number(_map, _key), do: nil

  defp get_in_map(map, keys) when is_map(map) and is_list(keys), do: get_in(map, keys)
  defp get_in_map(_map, _keys), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end
end
