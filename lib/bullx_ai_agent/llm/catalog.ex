defmodule BullXAIAgent.LLM.Catalog do
  @moduledoc """
  Resolves BullX LLM provider rows and caller-owned LLM spec strings.

  PostgreSQL is the durable provider catalog. This module reads through the
  reconstructible runtime cache and decrypts provider API keys only for resolved
  request options.
  """

  alias BullXAIAgent.LLM.{
    Catalog.Cache,
    Crypto,
    Provider,
    ProviderRegistry,
    ResolvedModel,
    ResolvedProvider,
    Spec
  }

  @spec list_providers() :: [Provider.t()]
  def list_providers, do: Cache.list()

  @spec find_provider(String.t()) :: {:ok, Provider.t()} | {:error, :not_found}
  def find_provider(provider_id) when is_binary(provider_id) do
    case Cache.get(provider_id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :not_found}
    end
  end

  @spec resolve_provider(String.t()) ::
          {:ok, ResolvedProvider.t()}
          | {:error,
             :not_found
             | {:unknown_req_llm_provider, String.t()}
             | {:decrypt_failed, String.t()}
             | {:invalid_provider_options, String.t(), term()}}
  def resolve_provider(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- find_provider(provider_id),
         {:ok, req_llm_provider, provider_module} <-
           ProviderRegistry.fetch(provider.req_llm_provider),
         {:ok, api_key} <- decrypt_api_key(provider),
         {:ok, provider_options} <- provider_options(provider_module, provider) do
      {:ok,
       %ResolvedProvider{
         provider_id: provider.provider_id,
         req_llm_provider: req_llm_provider,
         base_url: provider.base_url,
         opts: build_opts(api_key, provider_options)
       }}
    end
  end

  @spec resolve_model_spec(String.t()) ::
          {:ok, ResolvedModel.t()}
          | {:error,
             :not_found
             | {:invalid_llm_spec, term()}
             | {:unknown_req_llm_provider, String.t()}
             | {:decrypt_failed, String.t()}
             | {:invalid_provider_options, String.t(), term()}}
  def resolve_model_spec(spec) do
    with {:ok, %Spec{} = parsed} <- Spec.parse(spec),
         {:ok, %ResolvedProvider{} = provider} <- resolve_provider(parsed.provider_id) do
      {:ok,
       %ResolvedModel{
         provider_id: provider.provider_id,
         model_id: parsed.model_id,
         req_llm_provider: provider.req_llm_provider,
         model_input: model_input(provider, parsed.model_id),
         opts: provider.opts
       }}
    end
  end

  @spec resolve_model_spec!(String.t()) :: ResolvedModel.t() | no_return()
  def resolve_model_spec!(spec) do
    case resolve_model_spec(spec) do
      {:ok, resolved} ->
        resolved

      {:error, reason} ->
        raise ArgumentError, "could not resolve LLM spec #{inspect(spec)}: #{inspect(reason)}"
    end
  end

  defp decrypt_api_key(%Provider{
         encrypted_api_key: encrypted_api_key,
         id: id,
         provider_id: provider_id
       }) do
    case Crypto.decrypt_api_key(encrypted_api_key, id) do
      {:ok, api_key} -> {:ok, api_key}
      {:error, _reason} -> {:error, {:decrypt_failed, provider_id}}
    end
  end

  defp provider_options(_provider_module, %Provider{provider_options: nil}), do: {:ok, []}

  defp provider_options(_provider_module, %Provider{provider_options: options})
       when is_map(options) and map_size(options) == 0,
       do: {:ok, []}

  defp provider_options(provider_module, %Provider{
         provider_options: options,
         provider_id: provider_id
       })
       when is_map(options) do
    with {:ok, schema} <- provider_schema(provider_module, options, provider_id),
         {:ok, keyword} <- provider_options_keyword(options, schema, provider_id),
         :ok <- validate_provider_options(keyword, schema, provider_id) do
      {:ok, keyword}
    end
  end

  defp provider_options(_provider_module, %Provider{provider_id: provider_id}) do
    {:error, {:invalid_provider_options, provider_id, :not_a_json_object}}
  end

  defp provider_schema(provider_module, options, provider_id) do
    case {function_exported?(provider_module, :provider_schema, 0), map_size(options)} do
      {true, _size} ->
        {:ok, provider_module.provider_schema()}

      {false, 0} ->
        {:ok, nil}

      {false, _size} ->
        {:error, {:invalid_provider_options, provider_id, :provider_schema_missing}}
    end
  end

  defp provider_options_keyword(options, nil, _provider_id) when map_size(options) == 0,
    do: {:ok, []}

  defp provider_options_keyword(options, schema, provider_id) do
    schema_by_string =
      schema.schema
      |> Map.new(fn {key, spec} -> {Atom.to_string(key), {key, spec}} end)

    options
    |> Enum.reduce_while({:ok, []}, fn {raw_key, raw_value}, {:ok, acc} ->
      with {:ok, key, spec} <- normalize_option_key(raw_key, schema_by_string),
           {:ok, value} <- normalize_option_value(raw_value, spec) do
        {:cont, {:ok, [{key, value} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_provider_options, provider_id, reason}}}
      end
    end)
    |> case do
      {:ok, keyword} -> {:ok, Enum.reverse(keyword)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_option_key(key, schema_by_string) when is_binary(key) do
    case Map.fetch(schema_by_string, key) do
      {:ok, {atom_key, spec}} -> {:ok, atom_key, spec}
      :error -> {:error, {:unknown_key, key}}
    end
  end

  defp normalize_option_key(key, schema_by_string) when is_atom(key) do
    normalize_option_key(Atom.to_string(key), schema_by_string)
  end

  defp normalize_option_key(key, _schema_by_string), do: {:error, {:invalid_key, key}}

  defp normalize_option_value(value, spec) do
    case Keyword.fetch(spec, :type) do
      {:ok, {:in, choices}} -> normalize_in_value(value, choices)
      _other -> {:ok, value}
    end
  end

  defp normalize_in_value(value, choices) when is_binary(value) do
    choices
    |> Enum.find(&(is_atom(&1) and Atom.to_string(&1) == value))
    |> case do
      nil -> {:ok, value}
      atom -> {:ok, atom}
    end
  end

  defp normalize_in_value(value, _choices), do: {:ok, value}

  defp validate_provider_options(_keyword, nil, _provider_id), do: :ok

  defp validate_provider_options(keyword, schema, provider_id) do
    case NimbleOptions.validate(keyword, schema) do
      {:ok, _validated} ->
        :ok

      {:error, error} ->
        {:error, {:invalid_provider_options, provider_id, Exception.message(error)}}
    end
  end

  defp build_opts(api_key, provider_options) do
    []
    |> maybe_put(:api_key, api_key)
    |> maybe_put(:provider_options, provider_options)
  end

  defp model_input(%ResolvedProvider{} = provider, model_id) do
    %{provider: provider.req_llm_provider, id: model_id}
    |> maybe_map_put(:base_url, provider.base_url)
  end

  defp maybe_put(opts, _key, value) when value in [nil, "", []], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_map_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_map_put(map, key, value), do: Map.put(map, key, value)
end
