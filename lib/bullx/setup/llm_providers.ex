defmodule BullX.Setup.LLMProviders do
  @moduledoc false

  alias BullX.LLM.{Catalog, PluginProviders, Provider, ProviderRegistry, Writer}

  @spec status() :: map()
  def status do
    providers = public_providers()
    catalog = provider_catalog()

    %{
      complete?: providers != [],
      providers: providers,
      req_llm_providers: Enum.map(catalog, & &1.id),
      provider_catalog: catalog
    }
  end

  @spec provider_catalog() :: [map()]
  def provider_catalog do
    PluginProviders.available_extensions()
    |> Enum.map(&provider_catalog_entry/1)
    |> Enum.sort_by(& &1.id)
  end

  @spec public_providers() :: [map()]
  def public_providers do
    Catalog.list_providers()
    |> Enum.map(&public_provider/1)
  rescue
    _error -> []
  end

  @spec save_many(term()) :: {:ok, [map()]} | {:error, map()}
  def save_many(providers) when is_list(providers) do
    providers
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case save_one(attrs) do
        {:ok, provider} -> {:cont, {:ok, [public_provider(provider) | acc]}}
        {:error, reason} -> {:halt, {:error, normalize_error(reason)}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def save_many(_providers), do: {:error, %{field: "providers", message: "must be a list"}}

  @spec check(map()) :: {:ok, map()} | {:error, map()}
  def check(attrs) when is_map(attrs) do
    attrs = normalize_provider_attrs(attrs)

    with :ok <- validate_req_llm_provider(attrs),
         {:ok, _provider} <- validate_provider_shape(attrs),
         {:ok, ping} <- maybe_ping(attrs) do
      {:ok, %{provider: safe_provider_attrs(attrs), ping: ping}}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def check(_attrs), do: {:error, %{field: "provider", message: "must be an object"}}

  defp save_one(attrs) when is_map(attrs) do
    attrs = normalize_provider_attrs(attrs)

    attrs =
      case blank?(Map.get(attrs, :api_key)) and existing_provider?(attrs[:provider_id]) do
        true -> Map.delete(attrs, :api_key)
        false -> attrs
      end

    case Writer.put_provider(attrs) do
      {:ok, provider} -> {:ok, provider}
      {:ok, provider, _stale} -> {:ok, provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_provider_shape(attrs) do
    %Provider{}
    |> Provider.changeset(Map.delete(attrs, :api_key))
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp validate_req_llm_provider(%{req_llm_provider: provider}) when is_binary(provider) do
    with true <- provider in PluginProviders.available_provider_ids(),
         true <- ProviderRegistry.known?(provider) do
      :ok
    else
      _other -> {:error, {:unknown_req_llm_provider, provider}}
    end
  end

  defp validate_req_llm_provider(_attrs), do: {:error, {:missing_field, :req_llm_provider}}

  defp maybe_ping(%{test_model_id: model_id} = attrs)
       when is_binary(model_id) and model_id != "" do
    with {:ok, provider_atom, _module} <- ProviderRegistry.fetch(attrs.req_llm_provider) do
      model_input =
        %{provider: provider_atom, id: model_id}
        |> maybe_put(:base_url, attrs[:base_url])

      opts =
        []
        |> maybe_put(:api_key, attrs[:api_key])
        |> maybe_put(:provider_options, [])

      messages = [
        %ReqLLM.Message{
          role: :user,
          content: [ReqLLM.Message.ContentPart.text("Reply with ok.")]
        }
      ]

      case ReqLLM.generate_text(model_input, messages, opts) do
        {:ok, response} ->
          {:ok,
           %{
             status: "ok",
             text_preview: String.slice(ReqLLM.Response.text(response) || "", 0, 80)
           }}

        {:error, reason} ->
          {:error, {:provider_check_failed, inspect(reason)}}
      end
    end
  end

  defp maybe_ping(_attrs), do: {:ok, %{status: "not_run"}}

  defp public_provider(%Provider{} = provider) do
    %{
      id: provider.id,
      provider_id: provider.provider_id,
      req_llm_provider: provider.req_llm_provider,
      base_url: provider.base_url,
      provider_options: provider.provider_options || %{},
      api_key: %{
        present: not blank?(provider.encrypted_api_key),
        masked: mask(provider.encrypted_api_key)
      }
    }
  end

  defp safe_provider_attrs(attrs) do
    attrs
    |> Map.take([:provider_id, :req_llm_provider, :base_url, :provider_options])
    |> Map.put(:api_key, %{present: not blank?(attrs[:api_key])})
  end

  defp normalize_provider_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.update(:provider_options, %{}, &normalize_provider_options/1)
    |> Map.update(:provider_id, nil, &trim_or_nil/1)
    |> Map.update(:req_llm_provider, nil, &trim_or_nil/1)
    |> Map.update(:base_url, nil, &trim_or_nil/1)
    |> Map.update(:api_key, nil, &trim_or_nil/1)
    |> Map.update(:test_model_id, nil, &trim_or_nil/1)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "provider_id" -> :provider_id
      "req_llm_provider" -> :req_llm_provider
      "base_url" -> :base_url
      "api_key" -> :api_key
      "provider_options" -> :provider_options
      "test_model_id" -> :test_model_id
      other -> other
    end
  end

  defp normalize_provider_options(%{} = options), do: options
  defp normalize_provider_options(value) when value in [nil, ""], do: %{}

  defp normalize_provider_options(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> map
      _other -> value
    end
  end

  defp normalize_provider_options(value), do: value

  defp existing_provider?(provider_id) when is_binary(provider_id) do
    match?({:ok, _provider}, Catalog.find_provider(provider_id))
  end

  defp existing_provider?(_provider_id), do: false

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(list, key, value) when is_list(list), do: Keyword.put(list, key, value)

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value

  defp blank?(value), do: value in [nil, ""]
  defp mask(nil), do: nil
  defp mask(""), do: nil
  defp mask(_value), do: "******"

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    %{message: "validation failed", errors: changeset_errors(changeset)}
  end

  defp normalize_error({:missing_field, field}), do: %{field: field, message: "is required"}

  defp normalize_error({:unknown_req_llm_provider, provider}),
    do: %{field: "req_llm_provider", message: "unknown req_llm provider", details: provider}

  defp normalize_error({:provider_check_failed, message}),
    do: %{field: "provider", message: "provider check failed", details: message}

  defp normalize_error(reason), do: %{message: inspect(reason)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp provider_catalog_entry(%BullX.Plugins.Extension{} = extension) do
    module = extension.module

    %{
      id: extension_id(extension.id),
      label_key: "setup.llm.providers.#{extension_id(extension.id)}",
      default_base_url: provider_default_base_url(module),
      api_key_supported: provider_api_key_supported?(module),
      provider_options: provider_option_fields(module)
    }
  end

  defp extension_id(id) when is_binary(id), do: id
  defp extension_id(id) when is_atom(id), do: Atom.to_string(id)

  defp provider_default_base_url(module) when is_atom(module) and not is_nil(module) do
    case function_exported?(module, :default_base_url, 0) do
      true -> module.default_base_url()
      false -> nil
    end
  end

  defp provider_default_base_url(_module), do: nil

  defp provider_api_key_supported?(module) do
    provider_api_key_env?(module) or provider_schema_has_key?(module, :api_key)
  end

  defp provider_api_key_env?(module) when is_atom(module) and not is_nil(module) do
    case function_exported?(module, :default_env_key, 0) do
      true -> String.contains?(module.default_env_key(), ["API_KEY", "BEARER_TOKEN"])
      false -> false
    end
  end

  defp provider_api_key_env?(_module), do: false

  defp provider_schema_has_key?(module, key) when is_atom(module) and not is_nil(module) do
    with true <- function_exported?(module, :provider_schema, 0) do
      Keyword.has_key?(module.provider_schema().schema, key)
    else
      _other -> false
    end
  end

  defp provider_schema_has_key?(_module, _key), do: false

  defp provider_option_fields(module) when is_atom(module) and not is_nil(module) do
    with true <- function_exported?(module, :provider_schema, 0) do
      module.provider_schema().schema
      |> Keyword.delete(:api_key)
      |> Enum.map(&provider_option_field/1)
      |> Enum.sort_by(& &1.key)
    else
      _other -> []
    end
  end

  defp provider_option_fields(_module), do: []

  defp provider_option_field({key, opts}) do
    type = Keyword.get(opts, :type, :any)

    %{
      key: Atom.to_string(key),
      label: key |> Atom.to_string() |> String.replace("_", " "),
      input_type: provider_option_input_type(type),
      options: provider_option_select_options(type),
      required: Keyword.get(opts, :required, false),
      default: provider_option_default(opts),
      doc: Keyword.get(opts, :doc, "")
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
  defp provider_option_input_type({:list, {:in, _values}}), do: "select_list"

  defp provider_option_input_type({:list, item_type}) when item_type in [:string, :atom],
    do: "string_list"

  defp provider_option_input_type({:list, _item_type}), do: "json_list"
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
  defp provider_option_select_options({:list, {:in, values}}), do: Enum.map(values, &to_string/1)

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

  defp jsonable_provider_option_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: Atom.to_string(value)

  defp jsonable_provider_option_value(value) when is_list(value),
    do: Enum.map(value, &jsonable_provider_option_value/1)

  defp jsonable_provider_option_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), jsonable_provider_option_value(item)} end)
  end

  defp jsonable_provider_option_value(value), do: value
end
