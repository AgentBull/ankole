defmodule BullX.LLM.ProviderModelDiscovery do
  @moduledoc """
  Best-effort dynamic model discovery for configured LLM providers.

  Dynamic discovery enriches the local catalog with provider-reported model ids
  and limits. It does not replace BullX's provider/model rows: the result is a
  UI/readiness projection used when operators choose models during setup.
  """

  alias BullX.LLM.{ModelConfig, ModelDescriptor}

  @spec list_openai_compatible(atom(), keyword()) ::
          {:ok, [ModelDescriptor.t()]} | {:error, term()}
  def list_openai_compatible(provider_atom, opts) when is_atom(provider_atom) and is_list(opts) do
    request =
      opts
      |> base_request("/models")
      |> maybe_put_header("authorization", bearer_token(opts))

    with {:ok, models} <- get_model_list(request, "data") do
      {:ok, map_models(models, opts, provider_atom, &openai_compatible_descriptor/4)}
    end
  end

  @spec list_anthropic(keyword()) :: {:ok, [ModelDescriptor.t()]} | {:error, term()}
  def list_anthropic(opts) when is_list(opts) do
    request =
      opts
      |> base_request("/v1/models")
      |> maybe_put_header("x-api-key", api_key(opts))
      |> maybe_put_header("anthropic-version", anthropic_version(opts))

    with {:ok, models} <- get_model_list(request, "data") do
      {:ok, map_models(models, opts, :anthropic, &anthropic_descriptor/4)}
    end
  end

  @spec list_google(keyword()) :: {:ok, [ModelDescriptor.t()]} | {:error, term()}
  def list_google(opts) when is_list(opts) do
    request =
      opts
      |> base_request("/models")
      |> google_auth(opts)

    with {:ok, models} <- get_model_list(request, "models") do
      {:ok, map_models(models, opts, :google, &google_descriptor/4)}
    end
  end

  defp base_request(opts, url) do
    model_discovery_req_options()
    |> Keyword.put(:base_url, Keyword.fetch!(opts, :base_url))
    |> Keyword.put(:url, url)
    |> Keyword.put(:retry, false)
  end

  defp get_model_list(request, key) do
    case Req.get(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case Map.get(body, key) do
          models when is_list(models) -> {:ok, models}
          _other -> {:error, {:model_discovery_failed, status, :missing_model_list}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:model_discovery_failed, status, safe_body(body)}}

      {:error, reason} ->
        {:error, {:model_discovery_failed, reason}}
    end
  end

  defp map_models(models, opts, provider_atom, mapper) do
    provider_id = Keyword.fetch!(opts, :provider_id)

    # Preserve the configured BullX provider_id on every descriptor even when
    # the remote API only knows its adapter-native provider family.
    models
    |> Enum.map(&mapper.(provider_id, provider_atom, &1, local_model(provider_atom, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&String.downcase(&1.label || &1.model))
  end

  defp openai_compatible_descriptor(
         provider_id,
         provider_atom,
         %{"id" => model_id} = model,
         local
       )
       when is_binary(model_id) do
    %ModelDescriptor{
      provider_id: provider_id,
      model: model_id,
      label: string_value(model["name"]) || local_name(local) || model_id,
      context_window:
        first_integer([model["context_window"], model["context_length"], local_context(local)]),
      max_completion_tokens:
        first_integer([
          model["max_completion_tokens"],
          model["max_output_tokens"],
          local_output(local)
        ]),
      reasoning: local_reasoning(local),
      source: source(provider_atom, local)
    }
  end

  defp openai_compatible_descriptor(_provider_id, _provider_atom, _model, _local), do: nil

  defp anthropic_descriptor(provider_id, _provider_atom, %{"id" => model_id} = model, local)
       when is_binary(model_id) do
    %ModelDescriptor{
      provider_id: provider_id,
      model: model_id,
      label:
        string_value(model["display_name"]) || string_value(model["name"]) || local_name(local) ||
          model_id,
      context_window:
        first_integer([model["context_window"], model["context_length"], local_context(local)]),
      max_completion_tokens:
        first_integer([model["max_output_tokens"], model["max_tokens"], local_output(local)]),
      reasoning: local_reasoning(local),
      source: source(:anthropic, local)
    }
  end

  defp anthropic_descriptor(_provider_id, _provider_atom, _model, _local), do: nil

  defp google_descriptor(provider_id, _provider_atom, %{"name" => model_name} = model, local)
       when is_binary(model_name) do
    model_id =
      case model_name do
        "models/" <> id -> id
        id -> id
      end

    %ModelDescriptor{
      provider_id: provider_id,
      model: model_id,
      label: string_value(model["displayName"]) || local_name(local) || model_id,
      context_window: first_integer([model["inputTokenLimit"], local_context(local)]),
      max_completion_tokens: first_integer([model["outputTokenLimit"], local_output(local)]),
      reasoning: google_reasoning(model, local),
      source: source(:google, local)
    }
  end

  defp google_descriptor(_provider_id, _provider_atom, _model, _local), do: nil

  defp local_model(provider_atom, %{"id" => model_id}) when is_binary(model_id),
    do: local_model(provider_atom, model_id)

  defp local_model(:google, %{"name" => "models/" <> model_id}),
    do: local_model(:google, model_id)

  defp local_model(:google, %{"name" => model_id}) when is_binary(model_id),
    do: local_model(:google, model_id)

  defp local_model(provider_atom, model_id) when is_binary(model_id) do
    case LLMDB.model(provider_atom, model_id) do
      {:ok, %LLMDB.Model{} = model} -> model
      {:error, _reason} -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp local_model(_provider_atom, _model), do: nil

  defp local_name(%LLMDB.Model{name: name}) when is_binary(name), do: name
  defp local_name(_model), do: nil

  defp local_context(%LLMDB.Model{limits: limits}) when is_map(limits), do: limits[:context]
  defp local_context(_model), do: nil

  defp local_output(%LLMDB.Model{limits: limits}) when is_map(limits), do: limits[:output]
  defp local_output(_model), do: nil

  defp local_reasoning(%LLMDB.Model{capabilities: %{reasoning: %{enabled: true}}}) do
    %{efforts: ModelConfig.reasoning_efforts()}
  end

  defp local_reasoning(_model), do: %{efforts: [:none]}

  defp google_reasoning(%{"thinking" => true}, _local),
    do: %{efforts: ModelConfig.reasoning_efforts()}

  defp google_reasoning(_model, local), do: local_reasoning(local)

  defp source(_provider_atom, %LLMDB.Model{}), do: :dynamic
  defp source(_provider_atom, _local), do: :dynamic

  defp first_integer(values) do
    Enum.find_value(values, &integer_value/1)
  end

  defp integer_value(value) when is_integer(value) and value > 0, do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp string_value(value) when is_binary(value) and value != "", do: value
  defp string_value(_value), do: nil

  defp bearer_token(opts) do
    case api_key(opts) do
      value when is_binary(value) and value != "" -> "Bearer " <> value
      _other -> nil
    end
  end

  defp api_key(opts) do
    opts
    |> Keyword.get(:opts, [])
    |> Keyword.get(:api_key)
  end

  defp anthropic_version(opts) do
    opts
    |> provider_options()
    |> Keyword.get(:anthropic_version, "2023-06-01")
  end

  defp google_auth(request, opts) do
    case {api_key(opts), Keyword.get(provider_options(opts), :google_auth_header, false)} do
      {key, true} when is_binary(key) and key != "" ->
        maybe_put_header(request, "x-goog-api-key", key)

      {key, _header?} when is_binary(key) and key != "" ->
        Keyword.update(request, :params, [key: key], &[{:key, key} | &1])

      _other ->
        request
    end
  end

  defp provider_options(opts) do
    opts
    |> Keyword.get(:opts, [])
    |> Keyword.get(:provider_options, [])
  end

  defp maybe_put_header(opts, _header, nil), do: opts

  defp maybe_put_header(opts, header, value) do
    Keyword.update(opts, :headers, [{header, value}], &[{header, value} | &1])
  end

  defp model_discovery_req_options do
    :bullx
    |> Application.get_env(:llm, [])
    |> Keyword.get(:model_discovery_req_options, [])
  end

  defp safe_body(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp safe_body(body) when is_map(body), do: Map.take(body, ["error", "message"])
  defp safe_body(_body), do: nil
end
