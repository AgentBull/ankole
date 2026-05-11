defmodule BullXAIAgent.LLM.SetupContext do
  @moduledoc """
  Setup-time business logic for the LLM provider catalog and alias bindings.

  Pure data transformations and persistence orchestration consumed by the setup
  wizard. Functions in this module do not touch `Plug.Conn`; callers handle
  HTTP concerns separately.
  """

  alias BullXAIAgent.LLM.Catalog
  alias BullXAIAgent.LLM.Crypto
  alias BullXAIAgent.LLM.ProviderOptions
  alias BullXAIAgent.LLM.ResolvedProvider
  alias BullXAIAgent.LLM.Writer

  @aliases [:default, :fast, :heavy, :compression]
  @catalog Catalog
  @writer Writer
  @resolved_provider ResolvedProvider

  # ---------------------------------------------------------------------------
  # Read API
  # ---------------------------------------------------------------------------

  def provider_id_catalog do
    ReqLLM.Providers.list()
    |> Enum.map(&provider_catalog_entry/1)
  end

  def public_providers do
    @catalog
    |> apply(:list_providers, [])
    |> Enum.map(&public_provider/1)
  end

  def effective_alias_bindings do
    persisted = apply(@catalog, :list_alias_bindings, [])

    Enum.map(@aliases, fn alias_name ->
      case fetch_binding(persisted, alias_name) do
        nil ->
          default_alias_binding(alias_name)

        binding ->
          alias_binding(alias_name, binding, "operator_override")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Validation + persistence API
  # ---------------------------------------------------------------------------

  def normalize_providers(providers) when is_list(providers) do
    providers
    |> Enum.with_index()
    |> Enum.map(fn {provider, index} -> normalize_provider(provider, index) end)
    |> collect_provider_results()
    |> validate_provider_list()
  end

  def normalize_providers(_providers) do
    {:error, [error("payload", "providers must be a list", "providers")]}
  end

  def normalize_provider_attrs(attrs, path) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    {provider, errors} =
      {%{}, []}
      |> put_optional_string(attrs, "id", path)
      |> put_optional_string(attrs, "name", path)
      |> put_required_string(attrs, "provider_id", path)
      |> put_required_string(attrs, "model_id", path)
      |> put_optional_string(attrs, "base_url", path)
      |> put_optional_api_key(attrs)
      |> put_optional_inherit_from(attrs)
      |> put_provider_options(attrs, path)

    provider = put_default_provider_name(provider)

    errors =
      errors
      |> maybe_validate_name(provider, path)
      |> maybe_validate_length(provider, :provider_id, 64, path)
      |> maybe_validate_length(provider, :model_id, 128, path)

    case errors do
      [] -> {:ok, provider}
      [_ | _] -> {:error, errors}
    end
  end

  def normalize_alias_bindings(bindings, providers) do
    provider_names = MapSet.new(providers, &Map.fetch!(&1, :name))

    with {:ok, bindings} <- normalize_binding_payload(bindings),
         :ok <- validate_default_binding(bindings, provider_names),
         :ok <- validate_binding_targets(bindings, provider_names),
         :ok <- validate_alias_cycles(bindings) do
      {:ok, bindings}
    end
  end

  def resolve_inherited_api_keys(provider_attrs) do
    by_name = Map.new(provider_attrs, fn attrs -> {Map.fetch!(attrs, :name), attrs} end)

    provider_attrs
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case resolve_inherited_api_key(attrs, by_name) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, error} -> {:halt, {:error, [error]}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _errors} = error -> error
    end
  end

  def write_providers(providers) do
    Enum.reduce_while(providers, {:ok, []}, fn attrs, {:ok, written} ->
      case write_provider(attrs) do
        {:ok, provider} -> {:cont, {:ok, [provider | written]}}
        {:error, error} -> {:halt, {:error, writer_errors(error)}}
      end
    end)
  end

  def write_alias_bindings(bindings) do
    bindings = Enum.sort_by(bindings, &alias_binding_write_priority/1)

    Enum.reduce_while(bindings, :ok, fn
      {alias_name, nil}, :ok when alias_name != :default ->
        case apply(@writer, :delete_alias_binding, [alias_name]) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, writer_errors(error)}}
        end

      {alias_name, nil}, :ok ->
        {:halt,
         {:error,
          [error("config", "default provider binding is required", alias_path(alias_name))]}}

      {alias_name, binding}, :ok ->
        case apply(@writer, :put_alias_binding, [alias_name, binding]) do
          {:ok, _binding} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, writer_errors(error)}}
        end
    end)
  end

  def delete_absent_providers(providers) do
    submitted_ids =
      providers
      |> Enum.flat_map(fn
        %{id: id} when is_binary(id) -> [id]
        _provider -> []
      end)
      |> MapSet.new()

    submitted_names = MapSet.new(providers, &Map.fetch!(&1, :name))

    @catalog
    |> apply(:list_providers, [])
    |> Enum.reject(&submitted_provider?(&1, submitted_ids, submitted_names))
    |> Enum.reduce_while(:ok, fn provider, :ok ->
      case apply(@writer, :delete_provider, [provider.name]) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, writer_errors(error)}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Transient resolution for connectivity checks
  # ---------------------------------------------------------------------------

  def transient_resolved_provider(attrs) do
    provider_id = Map.fetch!(attrs, :provider_id)

    with {:ok, provider} <- provider_atom(provider_id),
         {:ok, provider_options} <-
           ProviderOptions.normalize_for_request(
             provider_id,
             Map.get(attrs, :provider_options, %{})
           ) do
      model =
        %{provider: provider, id: Map.fetch!(attrs, :model_id)}
        |> maybe_put_model_base_url(Map.get(attrs, :base_url))

      {:ok,
       struct(@resolved_provider,
         model: model,
         opts: transient_provider_opts(attrs, provider_options)
       )}
    end
  rescue
    error -> {:error, error}
  end

  def safe_generate_text(input, opts) do
    {module, function} =
      Application.get_env(:bullx, :setup_llm_generate_text, {BullXAIAgent, :generate_text})

    apply(module, function, [input, opts])
  rescue
    error -> {:error, error}
  end

  # ---------------------------------------------------------------------------
  # Error shape helpers
  # ---------------------------------------------------------------------------

  def error(kind, message, field) do
    %{
      "kind" => kind,
      "message" => message,
      "details" => %{"field" => field}
    }
  end

  def generic_error(reason) do
    %{
      "kind" => "unknown",
      "message" => inspect(reason),
      "details" => %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Provider catalog (req_llm metadata)
  # ---------------------------------------------------------------------------

  defp provider_catalog_entry(provider_id) do
    provider_id_string = Atom.to_string(provider_id)
    module = provider_module(provider_id)

    %{
      "id" => provider_id_string,
      "label" => provider_id_string,
      "default_base_url" => provider_default_base_url(module),
      "api_key_supported" => provider_api_key_supported?(provider_id, module),
      "provider_options" => provider_option_fields(provider_id)
    }
  end

  defp provider_module(provider_id) do
    case ReqLLM.Providers.get(provider_id) do
      {:ok, module} -> module
      _other -> nil
    end
  end

  defp provider_default_base_url(module) when is_atom(module) do
    case function_exported?(module, :default_base_url, 0) do
      true -> module.default_base_url()
      false -> nil
    end
  end

  defp provider_default_base_url(_module), do: nil

  defp provider_api_key_supported?(provider_id, module) do
    provider_api_key_env?(module) or provider_schema_has_key?(provider_id, :api_key)
  end

  defp provider_api_key_env?(module) when is_atom(module) do
    case function_exported?(module, :default_env_key, 0) do
      true -> String.contains?(module.default_env_key(), ["API_KEY", "BEARER_TOKEN"])
      false -> false
    end
  end

  defp provider_api_key_env?(_module), do: false

  defp provider_schema_has_key?(provider_id, key) do
    with {:ok, module} <- ReqLLM.Providers.get(provider_id),
         true <- function_exported?(module, :provider_schema, 0) do
      Keyword.has_key?(module.provider_schema().schema, key)
    else
      _other -> false
    end
  end

  defp provider_option_fields(provider_id) do
    with {:ok, module} <- ReqLLM.Providers.get(provider_id),
         true <- function_exported?(module, :provider_schema, 0) do
      module.provider_schema().schema
      |> Keyword.delete(:api_key)
      |> Enum.map(&provider_option_field/1)
      |> Enum.sort_by(&Map.fetch!(&1, "key"))
    else
      _other -> []
    end
  end

  defp provider_option_field({key, opts}) do
    type = Keyword.get(opts, :type, :any)

    %{
      "key" => Atom.to_string(key),
      "label" => key |> Atom.to_string() |> String.replace("_", " "),
      "input_type" => provider_option_input_type(type),
      "type" => inspect(type),
      "options" => provider_option_select_options(type),
      "required" => Keyword.get(opts, :required, false),
      "default" => provider_option_default(opts),
      "doc" => Keyword.get(opts, :doc, "")
    }
  end

  defp provider_option_input_type(:boolean), do: "boolean"
  defp provider_option_input_type(:integer), do: "integer"
  defp provider_option_input_type(:pos_integer), do: "integer"
  defp provider_option_input_type(:non_neg_integer), do: "integer"
  defp provider_option_input_type(:float), do: "float"
  defp provider_option_input_type(:string), do: "string"
  defp provider_option_input_type(:atom), do: "string"
  defp provider_option_input_type({:in, _values}), do: "select"
  defp provider_option_input_type({:or, types}), do: provider_option_or_input_type(types)
  defp provider_option_input_type(_type), do: "json"

  defp provider_option_or_input_type(types) do
    select_options =
      types
      |> Enum.flat_map(&provider_option_select_options/1)
      |> Enum.uniq()

    cond do
      select_options != [] -> "select"
      Enum.all?(types, &(&1 in [:atom, :string])) -> "string"
      Enum.all?(types, &(&1 in [:integer, :pos_integer, :non_neg_integer])) -> "integer"
      true -> "json"
    end
  end

  defp provider_option_select_options({:in, values}), do: Enum.map(values, &to_string/1)

  defp provider_option_select_options({:or, types}) do
    types
    |> Enum.flat_map(&provider_option_select_options/1)
    |> Enum.uniq()
  end

  defp provider_option_select_options(_type), do: []

  defp provider_option_default(opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, value} -> jsonable_provider_option_value(value)
      :error -> nil
    end
  end

  defp jsonable_provider_option_value(value) when is_atom(value), do: Atom.to_string(value)

  defp jsonable_provider_option_value(value) when is_list(value),
    do: Enum.map(value, &jsonable_provider_option_value/1)

  defp jsonable_provider_option_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), jsonable_provider_option_value(item)} end)
  end

  defp jsonable_provider_option_value(value), do: value

  # ---------------------------------------------------------------------------
  # Persisted provider projection
  # ---------------------------------------------------------------------------

  defp public_provider(provider) do
    api_key_status =
      case present_binary?(Map.get(provider, :encrypted_api_key)) do
        true -> "stored"
        false -> "missing"
      end

    %{
      "id" => Map.get(provider, :id),
      "name" => Map.get(provider, :name),
      "provider_id" => Map.get(provider, :provider_id),
      "model_id" => Map.get(provider, :model_id),
      "base_url" => Map.get(provider, :base_url),
      "provider_options" => Map.get(provider, :provider_options) || %{},
      "encrypted_api_key" => nil,
      "api_key" => "",
      "secret_status" => %{"api_key" => api_key_status}
    }
  end

  # ---------------------------------------------------------------------------
  # Alias binding projection
  # ---------------------------------------------------------------------------

  defp fetch_binding(bindings, alias_name) when is_map(bindings) do
    Map.get(bindings, alias_name) || Map.get(bindings, Atom.to_string(alias_name))
  end

  defp fetch_binding(_bindings, _alias_name), do: nil

  defp default_alias_binding(:default) do
    %{
      "alias_name" => "default",
      "kind" => nil,
      "target" => nil,
      "source" => "missing"
    }
  end

  defp default_alias_binding(alias_name) do
    %{
      "alias_name" => Atom.to_string(alias_name),
      "kind" => "alias",
      "target" => Atom.to_string(fallback_alias(alias_name)),
      "source" => "fallback_provider"
    }
  end

  defp fallback_alias(:compression), do: :fast
  defp fallback_alias(_alias_name), do: :default

  defp alias_binding(alias_name, {:provider, provider_name}, source) do
    %{
      "alias_name" => Atom.to_string(alias_name),
      "kind" => "provider",
      "target" => provider_name,
      "source" => source
    }
  end

  defp alias_binding(alias_name, {:alias, target_alias}, source) do
    %{
      "alias_name" => Atom.to_string(alias_name),
      "kind" => "alias",
      "target" => Atom.to_string(target_alias),
      "source" => source
    }
  end

  # ---------------------------------------------------------------------------
  # Provider attrs normalization
  # ---------------------------------------------------------------------------

  defp normalize_provider(provider, index) when is_map(provider) do
    normalize_provider_attrs(provider, "providers[#{index}]")
  end

  defp normalize_provider(_provider, index) do
    {:error, [error("payload", "provider must be an object", "providers[#{index}]")]}
  end

  defp collect_provider_results(results) do
    {providers, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, provider}, {providers, errors} -> {[provider | providers], errors}
        {:error, provider_errors}, {providers, errors} -> {providers, errors ++ provider_errors}
      end)

    case errors do
      [] -> {:ok, Enum.reverse(providers)}
      [_ | _] -> {:error, errors}
    end
  end

  defp validate_provider_list({:error, _errors} = error), do: error

  defp validate_provider_list({:ok, []}) do
    {:error, [error("config", "at least one provider is required", "providers")]}
  end

  defp validate_provider_list({:ok, providers}) do
    case duplicate_provider_name(providers) do
      nil -> {:ok, providers}
      name -> {:error, [error("config", "provider name #{name} is duplicated", "providers")]}
    end
  end

  defp duplicate_provider_name(providers) do
    providers
    |> Enum.map(&Map.fetch!(&1, :name))
    |> Enum.reduce_while(MapSet.new(), fn name, seen ->
      case MapSet.member?(seen, name) do
        true -> {:halt, name}
        false -> {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  defp put_required_string({provider, errors}, attrs, field, path) do
    case normalized_string(Map.get(attrs, field)) do
      "" ->
        {provider, errors ++ [error("config", "#{field} is required", field_path(path, field))]}

      value ->
        {Map.put(provider, String.to_existing_atom(field), value), errors}
    end
  end

  defp put_optional_string({provider, errors}, attrs, field, _path) do
    case normalized_string(Map.get(attrs, field)) do
      "" -> {provider, errors}
      value -> {Map.put(provider, String.to_existing_atom(field), value), errors}
    end
  end

  defp put_optional_api_key({provider, errors}, attrs) do
    cond do
      not Map.has_key?(attrs, "api_key") ->
        {provider, errors}

      is_nil(Map.get(attrs, "api_key")) ->
        {Map.put(provider, :api_key, nil), errors}

      normalized_string(Map.get(attrs, "api_key")) == "" ->
        {provider, errors}

      true ->
        {Map.put(provider, :api_key, normalized_string(Map.get(attrs, "api_key"))), errors}
    end
  end

  defp put_optional_inherit_from({provider, errors}, attrs) do
    case normalized_string(Map.get(attrs, "api_key_inherits_from")) do
      "" -> {provider, errors}
      value -> {Map.put(provider, :api_key_inherits_from, value), errors}
    end
  end

  defp put_provider_options({provider, errors}, attrs, path) do
    case normalize_provider_options(Map.get(attrs, "provider_options")) do
      {:ok, options} ->
        validate_provider_options({Map.put(provider, :provider_options, options), errors}, path)

      {:error, message} ->
        {provider, errors ++ [error("config", message, field_path(path, "provider_options"))]}
    end
  end

  defp validate_provider_options(
         {%{provider_id: provider_id, provider_options: options} = provider, errors},
         path
       ) do
    case req_llm_provider_known?(provider_id) do
      true ->
        case ProviderOptions.normalize_for_storage(provider_id, options) do
          {:ok, normalized} ->
            {Map.put(provider, :provider_options, normalized), errors}

          {:error, reason} ->
            {provider, errors ++ [provider_options_error(reason, path)]}
        end

      false ->
        {provider, errors}
    end
  end

  defp validate_provider_options({provider, errors}, _path), do: {provider, errors}

  defp req_llm_provider_known?(provider_id) do
    Enum.any?(ReqLLM.Providers.list(), &(Atom.to_string(&1) == provider_id))
  end

  defp normalize_provider_options(nil), do: {:ok, %{}}

  defp normalize_provider_options(options) when is_map(options),
    do: {:ok, stringify_keys(options)}

  defp normalize_provider_options(options) when is_binary(options) do
    case String.trim(options) do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          {:ok, _other} -> {:error, "provider_options must be a JSON object"}
          {:error, _reason} -> {:error, "provider_options must be valid JSON"}
        end
    end
  end

  defp normalize_provider_options(_options), do: {:error, "provider_options must be an object"}

  defp put_default_provider_name(%{name: name} = provider) when is_binary(name), do: provider

  defp put_default_provider_name(%{provider_id: provider_id, model_id: model_id} = provider) do
    Map.put(provider, :name, "#{provider_id}/#{model_id}")
  end

  defp put_default_provider_name(provider), do: provider

  defp maybe_validate_name(errors, provider, path) do
    case Map.get(provider, :name) do
      name when is_binary(name) ->
        case Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,192}$/, name) do
          true ->
            errors

          false ->
            errors ++ [error("config", "name has invalid format", field_path(path, "name"))]
        end

      _other ->
        errors
    end
  end

  defp maybe_validate_length(errors, provider, field, max, path) do
    case Map.get(provider, field) do
      value when is_binary(value) and byte_size(value) <= max ->
        errors

      value when is_binary(value) ->
        errors ++
          [error("config", "#{field} is too long", field_path(path, Atom.to_string(field)))]

      _other ->
        errors
    end
  end

  # ---------------------------------------------------------------------------
  # Alias binding normalization
  # ---------------------------------------------------------------------------

  defp normalize_binding_payload(bindings) when is_map(bindings) do
    bindings
    |> Enum.map(fn {alias_name, binding} -> normalize_binding(alias_name, binding) end)
    |> collect_binding_results()
    |> validate_duplicate_bindings()
  end

  defp normalize_binding_payload(bindings) when is_list(bindings) do
    bindings
    |> Enum.map(&normalize_binding_from_row/1)
    |> collect_binding_results()
    |> validate_duplicate_bindings()
  end

  defp normalize_binding_payload(_bindings) do
    {:error, [error("payload", "alias_bindings must be an object or list", "alias_bindings")]}
  end

  defp normalize_binding_from_row(%{} = row) do
    row = stringify_keys(row)

    case Map.get(row, "alias_name") do
      nil -> {:error, [error("config", "alias_name is required", "alias_bindings")]}
      alias_name -> normalize_binding(alias_name, row)
    end
  end

  defp normalize_binding_from_row(_row) do
    {:error, [error("payload", "alias binding must be an object", "alias_bindings")]}
  end

  defp normalize_binding(alias_name, binding) do
    case alias_atom(alias_name) do
      {:ok, alias_atom} -> do_normalize_binding(alias_atom, binding)
      {:error, error} -> {:error, [error]}
    end
  end

  defp do_normalize_binding(alias_name, nil), do: {:ok, {alias_name, nil}}

  defp do_normalize_binding(alias_name, binding) when is_map(binding) do
    binding = stringify_keys(binding)

    case normalized_string(Map.get(binding, "kind")) do
      kind when kind in ["", "none"] ->
        {:ok, {alias_name, nil}}

      kind when kind in ["default", "default_provider", "fallback_provider", "alias"] ->
        normalize_alias_target_binding(alias_name, binding)

      "provider" ->
        normalize_provider_binding(alias_name, binding)

      kind ->
        {:error,
         [
           error(
             "config",
             "unsupported alias binding kind #{inspect(kind)}",
             alias_path(alias_name)
           )
         ]}
    end
  end

  defp do_normalize_binding(alias_name, _binding) do
    {:error,
     [error("payload", "alias binding must be an object or null", alias_path(alias_name))]}
  end

  defp normalize_provider_binding(alias_name, binding) do
    case binding_target(binding, ["target", "provider_name", "target_provider"]) do
      "" ->
        {:error, [error("config", "provider target is required", alias_path(alias_name))]}

      provider_name ->
        {:ok, {alias_name, {:provider, provider_name}}}
    end
  end

  defp normalize_alias_target_binding(alias_name, binding) do
    target =
      binding
      |> binding_target(["target", "target_alias"])
      |> default_target_alias(alias_name)

    case alias_atom(target) do
      {:ok, target_alias} ->
        {:ok, {alias_name, {:alias, target_alias}}}

      {:error, _error} ->
        {:error, [unknown_alias_target_error(alias_name, target)]}
    end
  end

  defp default_target_alias("", alias_name), do: fallback_alias(alias_name)
  defp default_target_alias(target, _alias_name), do: target

  defp binding_target(binding, keys) do
    keys
    |> Enum.map(&Map.get(binding, &1))
    |> Enum.find_value("", fn value ->
      case normalized_string(value) do
        "" -> nil
        target -> target
      end
    end)
  end

  defp collect_binding_results(results) do
    {bindings, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, binding}, {bindings, errors} -> {[binding | bindings], errors}
        {:error, binding_errors}, {bindings, errors} -> {bindings, errors ++ binding_errors}
      end)

    case errors do
      [] -> {:ok, Enum.reverse(bindings)}
      [_ | _] -> {:error, errors}
    end
  end

  defp validate_duplicate_bindings({:error, _errors} = error), do: error

  defp validate_duplicate_bindings({:ok, bindings}) do
    bindings
    |> Enum.map(fn {alias_name, _binding} -> alias_name end)
    |> Enum.reduce_while(MapSet.new(), fn alias_name, seen ->
      case MapSet.member?(seen, alias_name) do
        true -> {:halt, alias_name}
        false -> {:cont, MapSet.put(seen, alias_name)}
      end
    end)
    |> case do
      %MapSet{} ->
        {:ok, bindings}

      duplicate ->
        {:error, [error("config", "duplicate alias binding #{duplicate}", alias_path(duplicate))]}
    end
  end

  defp validate_default_binding(bindings, provider_names) do
    case List.keyfind(bindings, :default, 0) do
      {:default, {:provider, provider_name}} ->
        case MapSet.member?(provider_names, provider_name) do
          true -> :ok
          false -> {:error, [unknown_provider_binding_error(:default, provider_name)]}
        end

      {:default, _target} ->
        {:error, [error("config", "default provider binding is required", alias_path(:default))]}

      nil ->
        {:error, [error("config", "default provider binding is required", alias_path(:default))]}
    end
  end

  defp validate_binding_targets(bindings, provider_names) do
    errors =
      bindings
      |> Enum.flat_map(fn
        {alias_name, {:provider, provider_name}} ->
          case MapSet.member?(provider_names, provider_name) do
            true -> []
            false -> [unknown_provider_binding_error(alias_name, provider_name)]
          end

        {:default, {:alias, _target_alias}} ->
          [error("config", "default provider binding is required", alias_path(:default))]

        {alias_name, {:alias, target_alias}} ->
          validate_alias_target(alias_name, target_alias)

        _binding ->
          []
      end)

    case errors do
      [] -> :ok
      [_ | _] -> {:error, errors}
    end
  end

  defp unknown_provider_binding_error(alias_name, provider_name) do
    error(
      "config",
      "alias #{alias_name} points at unknown provider #{provider_name}",
      alias_path(alias_name)
    )
  end

  defp unknown_alias_target_error(alias_name, target_alias) do
    error(
      "config",
      "alias #{alias_name} points at unknown model alias #{target_alias}",
      alias_path(alias_name)
    )
  end

  defp validate_alias_target(alias_name, target_alias) do
    case target_alias in @aliases do
      true ->
        []

      false ->
        [unknown_alias_target_error(alias_name, target_alias)]
    end
  end

  defp validate_alias_cycles(bindings) do
    bindings
    |> effective_alias_graph()
    |> find_alias_cycle()
    |> case do
      nil -> :ok
      cycle -> {:error, [alias_cycle_error(cycle)]}
    end
  end

  defp effective_alias_graph(bindings) do
    bindings
    |> Enum.flat_map(fn
      {_alias_name, nil} -> []
      {alias_name, target} -> [{alias_name, target}]
    end)
    |> Map.new()
    |> add_implicit_alias_fallbacks()
  end

  defp add_implicit_alias_fallbacks(bindings) do
    bindings
    |> Map.put_new(:fast, {:alias, :default})
    |> Map.put_new(:heavy, {:alias, :default})
    |> Map.put_new(:compression, {:alias, :fast})
  end

  defp find_alias_cycle(bindings) do
    Enum.find_value(@aliases, &alias_cycle_from(&1, bindings, []))
  end

  defp alias_cycle_from(alias_name, bindings, path) do
    case alias_name in path do
      true ->
        Enum.reverse([alias_name | path])

      false ->
        case Map.get(bindings, alias_name) do
          {:alias, target_alias} -> alias_cycle_from(target_alias, bindings, [alias_name | path])
          _other -> nil
        end
    end
  end

  defp alias_cycle_error(cycle) do
    cycle_path = Enum.map_join(cycle, " -> ", &":#{&1}")
    error("config", "model alias cycle detected: #{cycle_path}", "alias_bindings")
  end

  # ---------------------------------------------------------------------------
  # API key inheritance
  # ---------------------------------------------------------------------------

  defp resolve_inherited_api_key(attrs, by_name) do
    cond do
      not Map.has_key?(attrs, :api_key_inherits_from) ->
        {:ok, attrs}

      Map.has_key?(attrs, :api_key) ->
        # Explicit api_key (including explicit nil to clear) overrides inherit.
        {:ok, Map.delete(attrs, :api_key_inherits_from)}

      true ->
        source_name = Map.fetch!(attrs, :api_key_inherits_from)

        case fetch_inherited_plaintext(source_name, by_name) do
          {:ok, plaintext} ->
            {:ok,
             attrs
             |> Map.put(:api_key, plaintext)
             |> Map.delete(:api_key_inherits_from)}

          {:error, reason} ->
            {:error,
             error(
               "config",
               "cannot inherit api_key from #{source_name}: #{reason}",
               "api_key_inherits_from"
             )}
        end
    end
  end

  defp fetch_inherited_plaintext(source_name, by_name) do
    case Map.get(by_name, source_name) do
      %{api_key: api_key} when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      _other ->
        fetch_inherited_plaintext_from_catalog(source_name)
    end
  end

  defp fetch_inherited_plaintext_from_catalog(source_name) do
    with {:ok, provider} <- apply(@catalog, :find_provider, [source_name]),
         encrypted when is_binary(encrypted) and encrypted != "" <-
           Map.get(provider, :encrypted_api_key),
         {:ok, plaintext} <-
           Crypto.decrypt_api_key(encrypted, provider.id) do
      {:ok, plaintext}
    else
      {:error, :not_found} -> {:error, "unknown source"}
      {:error, _reason} -> {:error, "decrypt failed"}
      _other -> {:error, "source has no stored api_key"}
    end
  end

  # ---------------------------------------------------------------------------
  # Provider writes
  # ---------------------------------------------------------------------------

  defp write_provider(%{} = attrs) do
    case existing_provider(attrs) do
      {:ok, provider} -> apply(@writer, :update_provider, [provider, attrs])
      {:error, :not_found} -> apply(@writer, :put_provider, [attrs])
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_provider(%{id: id}) when is_binary(id) do
    apply(@catalog, :find_provider_by_id, [id])
  end

  defp existing_provider(%{name: name}) do
    apply(@catalog, :find_provider, [name])
  end

  defp submitted_provider?(provider, submitted_ids, submitted_names) do
    MapSet.member?(submitted_ids, provider.id) or MapSet.member?(submitted_names, provider.name)
  end

  defp alias_binding_write_priority({_alias_name, {:provider, _provider_name}}), do: 0
  defp alias_binding_write_priority({_alias_name, nil}), do: 1
  defp alias_binding_write_priority({_alias_name, {:alias, _target_alias}}), do: 2

  # ---------------------------------------------------------------------------
  # Transient (in-memory) resolution for connectivity checks
  # ---------------------------------------------------------------------------

  defp maybe_put_model_base_url(model, nil), do: model
  defp maybe_put_model_base_url(model, base_url), do: Map.put(model, :base_url, base_url)

  defp transient_provider_opts(attrs, provider_options) do
    []
    |> maybe_put_opt(:api_key, transient_api_key(attrs))
    |> maybe_put_provider_options_opt(provider_options)
  end

  defp transient_api_key(%{api_key: api_key}), do: api_key

  defp transient_api_key(%{api_key_inherits_from: source_name}) do
    case fetch_inherited_plaintext_from_catalog(source_name) do
      {:ok, plaintext} -> plaintext
      {:error, _reason} -> nil
    end
  end

  defp transient_api_key(%{name: name, provider_id: provider_id}) do
    with {:ok, provider} <- apply(@catalog, :find_provider, [name]),
         true <- Map.get(provider, :provider_id) == provider_id,
         encrypted when is_binary(encrypted) and encrypted != "" <-
           Map.get(provider, :encrypted_api_key),
         {:ok, api_key} <- Crypto.decrypt_api_key(encrypted, provider.id) do
      api_key
    else
      _other -> nil
    end
  end

  defp transient_api_key(_attrs), do: nil

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_provider_options_opt(opts, []), do: opts

  defp maybe_put_provider_options_opt(opts, options),
    do: Keyword.put(opts, :provider_options, options)

  defp provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> {:error, error("config", "unknown provider #{provider_id}", "provider.provider_id")}
      provider -> {:ok, provider}
    end
  end

  # ---------------------------------------------------------------------------
  # Writer error shaping
  # ---------------------------------------------------------------------------

  defp writer_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &error("config", &1, Atom.to_string(field)))
    end)
  end

  defp writer_errors([%{} | _] = errors), do: errors
  defp writer_errors(%{} = error), do: [error]
  defp writer_errors(error), do: [generic_error(error)]

  defp provider_options_error({:unknown_options, [option | _]}, path) do
    error(
      "config",
      "unknown provider option #{option}",
      field_path(path, "provider_options.#{option}")
    )
  end

  defp provider_options_error(
         %NimbleOptions.ValidationError{keys_path: [option | _]} = reason,
         path
       ) do
    error(
      "config",
      Exception.message(reason),
      field_path(path, "provider_options.#{option}")
    )
  end

  defp provider_options_error(reason, path) do
    error(
      "config",
      "provider_options are invalid: #{inspect(reason)}",
      field_path(path, "provider_options")
    )
  end

  # ---------------------------------------------------------------------------
  # Pure utilities
  # ---------------------------------------------------------------------------

  defp alias_atom(value) when value in [:default, :fast, :heavy, :compression], do: {:ok, value}
  defp alias_atom("default"), do: {:ok, :default}
  defp alias_atom("fast"), do: {:ok, :fast}
  defp alias_atom("heavy"), do: {:ok, :heavy}
  defp alias_atom("compression"), do: {:ok, :compression}

  defp alias_atom(value) do
    {:error, error("config", "unknown alias #{inspect(value)}", "alias_bindings")}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} when is_binary(key) -> {key, stringify_nested(value)}
    end)
  end

  defp stringify_nested(%_{} = struct), do: struct
  defp stringify_nested(map) when is_map(map), do: stringify_keys(map)
  defp stringify_nested(list) when is_list(list), do: Enum.map(list, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp normalized_string(nil), do: ""
  defp normalized_string(value) when is_binary(value), do: String.trim(value)
  defp normalized_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalized_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalized_string(_value), do: ""

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp field_path(path, field), do: [path, field] |> Enum.reject(&(&1 == "")) |> Enum.join(".")
  defp alias_path(alias_name), do: "alias_bindings.#{alias_name}"
end
