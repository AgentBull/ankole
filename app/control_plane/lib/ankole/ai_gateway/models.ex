defmodule Ankole.AIGateway.Models do
  @moduledoc """
  Projects configured AIGateway model bindings as an OpenRouter-style catalog.

  The catalog lists metadata for every active configured provider row and adds
  agent-local aliases for agent credentials. The response shape follows
  OpenRouter, but model ids use Ankole selectors.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ModelSelectors
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers

  @doc """
  Lists model selectors visible to one subject.

  Agents see every explicit provider/model selector plus their own aliases.
  Admin humans see only explicit provider/model selectors because aliases are
  agent-local names and collide across agents.
  """
  @spec list_models(String.t(), String.t(), map()) :: {:ok, map()}
  def list_models(subject_uid, subject_type, params \\ %{})

  def list_models(subject_uid, subject_type, params)
      when is_binary(subject_uid) and is_binary(subject_type) and is_map(params) do
    models =
      subject_uid
      |> subject_model_entries(subject_type)
      |> filter_model_entries(params)
      |> sort_model_entries(params)

    {:ok, %{"data" => models}}
  end

  defp subject_model_entries(subject_uid, "agent") do
    explicit_provider_entries() ++ agent_alias_entries(subject_uid)
  end

  defp subject_model_entries(_subject_uid, "admin_human") do
    explicit_provider_entries()
  end

  defp subject_model_entries(_subject_uid, _subject_type), do: []

  defp explicit_provider_entries do
    ProviderConfigs.list_active_providers()
    |> Enum.flat_map(fn provider ->
      {:ok, models} = ModelMetadata.list_provider_model_metadata(provider)

      Enum.map(models, fn metadata ->
        selector = "#{provider.provider_id}/#{metadata["id"]}"
        ModelMetadata.openrouter_entry(metadata, selector, selector)
      end)
    end)
  end

  defp agent_alias_entries(agent_uid) do
    case ModelProfiles.get_model_profiles(agent_uid) do
      {:ok, profiles} ->
        profiles
        |> Enum.flat_map(fn {profile, attrs} ->
          case ModelProfiles.profile_capability(profile) do
            {:ok, capability} ->
              selector_entries(
                capability,
                ModelSelectors.public_selector(capability, profile),
                attrs
              )

            {:error, _reason} ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp selector_entries(capability, alias_selector, attrs) when is_map(attrs) do
    with %{"provider_id" => provider_id, "model" => model} when is_binary(model) <- attrs,
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- Providers.ensure_capability_supported(provider_kind, capability),
         {:ok, metadata} <- ModelMetadata.model_metadata(provider, model, capability: capability) do
      explicit_selector = "#{provider.provider_id}/#{model}"

      [ModelMetadata.openrouter_entry(metadata, alias_selector, explicit_selector)]
    else
      _reason -> []
    end
  end

  defp selector_entries(_capability, _alias_selector, _attrs), do: []

  # The filters mirror OpenRouter query parameters but operate on the local
  # configured catalog. Unknown upstream-specific details stay at safe defaults.
  defp filter_model_entries(entries, params) do
    entries
    |> filter_by_modalities("output_modalities", params, default: :all)
    |> filter_by_modalities("input_modalities", params, default: :all)
    |> filter_by_supported_parameters(params)
    |> filter_by_query(params)
    |> filter_by_context(params)
    |> filter_by_price(params)
  end

  defp filter_by_modalities(entries, key, params, opts) do
    case comma_filter(Map.get(params, key), Keyword.fetch!(opts, :default)) do
      :all ->
        entries

      requested ->
        Enum.filter(entries, fn entry ->
          modalities = get_in(entry, ["architecture", key]) || []
          Enum.any?(requested, &(&1 in modalities))
        end)
    end
  end

  defp filter_by_supported_parameters(entries, params) do
    case comma_filter(Map.get(params, "supported_parameters"), :all) do
      :all ->
        entries

      requested ->
        Enum.filter(entries, fn entry ->
          supported = Map.get(entry, "supported_parameters", [])
          Enum.all?(requested, &(&1 in supported))
        end)
    end
  end

  defp filter_by_query(entries, %{"q" => query}) when is_binary(query) do
    query = query |> String.trim() |> String.downcase()

    case query do
      "" ->
        entries

      query ->
        Enum.filter(entries, fn entry ->
          [entry["id"], entry["name"], entry["canonical_slug"], entry["description"]]
          |> Enum.any?(fn value ->
            is_binary(value) and String.contains?(String.downcase(value), query)
          end)
        end)
    end
  end

  defp filter_by_query(entries, _params), do: entries

  defp filter_by_context(entries, %{"context" => value}) do
    case integer_filter(value) do
      {:ok, minimum} ->
        Enum.filter(entries, &(context_length(&1) >= minimum))

      :error ->
        entries
    end
  end

  defp filter_by_context(entries, _params), do: entries

  defp filter_by_price(entries, params) do
    entries
    |> filter_by_price_bound(Map.get(params, "min_price"), :min)
    |> filter_by_price_bound(Map.get(params, "max_price"), :max)
  end

  # OpenRouter-compatible filters should be forgiving. Invalid numeric filters
  # are ignored so a bad query parameter does not hide the whole local catalog.
  defp filter_by_price_bound(entries, nil, _bound), do: entries

  defp filter_by_price_bound(entries, value, bound) do
    case number_filter(value) do
      {:ok, price} ->
        Enum.filter(entries, fn entry ->
          prompt_price = price_value(get_in(entry, ["pricing", "prompt"]))

          case bound do
            :min -> prompt_price >= price
            :max -> prompt_price <= price
          end
        end)

      :error ->
        entries
    end
  end

  defp sort_model_entries(entries, %{"sort" => "context-high-to-low"}) do
    Enum.sort_by(entries, &context_length/1, :desc)
  end

  defp sort_model_entries(entries, %{"sort" => "pricing-low-to-high"}) do
    Enum.sort_by(entries, &price_value(get_in(&1, ["pricing", "prompt"])), :asc)
  end

  defp sort_model_entries(entries, %{"sort" => "pricing-high-to-low"}) do
    Enum.sort_by(entries, &price_value(get_in(&1, ["pricing", "prompt"])), :desc)
  end

  defp sort_model_entries(entries, %{"sort" => "newest"}) do
    Enum.sort_by(entries, &Map.get(&1, "created", 0), :desc)
  end

  defp sort_model_entries(entries, _params), do: entries

  defp comma_filter(nil, default), do: default
  defp comma_filter("", default), do: default

  defp comma_filter(value, _default) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      ["all"] -> :all
      [] -> :all
      values -> values
    end
  end

  defp comma_filter(_value, default), do: default

  defp integer_filter(value) when is_integer(value), do: {:ok, value}

  defp integer_filter(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _value -> :error
    end
  end

  defp integer_filter(_value), do: :error

  defp number_filter(value) when is_number(value), do: {:ok, value / 1}

  defp number_filter(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _value -> :error
    end
  end

  defp number_filter(_value), do: :error

  defp price_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp price_value(value) when is_number(value), do: value / 1
  defp price_value(_value), do: 0.0

  defp context_length(entry) do
    case Map.get(entry, "context_length") do
      value when is_integer(value) -> value
      _value -> 0
    end
  end
end
