defmodule Ankole.AIGateway.Models do
  @moduledoc """
  Projects configured AIGateway model bindings as an OpenRouter-style catalog.

  The catalog is configuration-backed rather than a live upstream proxy. This
  keeps model visibility tied to Ankole provider rows and agent model profiles,
  which is the same truth used by runtime dispatch.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers
  alias Ankole.Principals
  alias Ankole.Principals.Agent

  @base_supported_parameters ~w(
    temperature top_p max_tokens max_output_tokens tools tool_choice metadata
    reasoning reasoningEffort text textVerbosity
  )

  @doc """
  Lists model selectors visible to one subject.

  Agents see their own aliases and explicit provider/model selectors. Admin
  humans see explicit selectors across active agents, which is useful for
  Console inspection without exposing agent aliases as global names.
  """
  @spec list_models(String.t(), String.t(), map()) :: {:ok, map()}
  def list_models(subject_uid, subject_type, params \\ %{})

  def list_models(subject_uid, subject_type, params)
      when is_binary(subject_uid) and is_binary(subject_type) and is_map(params) do
    models =
      subject_uid
      |> subject_model_entries(subject_type)
      |> Enum.uniq_by(& &1["id"])
      |> filter_model_entries(params)
      |> sort_model_entries(params)

    {:ok, %{"data" => models}}
  end

  defp subject_model_entries(subject_uid, "agent") do
    agent_profile_entries(subject_uid, include_aliases?: true)
  end

  defp subject_model_entries(_subject_uid, "admin_human") do
    Principals.list_active_agents()
    |> Enum.flat_map(fn %{agent: %Agent{uid: agent_uid}} ->
      agent_profile_entries(agent_uid, include_aliases?: false)
    end)
  end

  defp subject_model_entries(_subject_uid, _subject_type), do: []

  defp agent_profile_entries(agent_uid, opts) do
    case ModelProfiles.get_model_profiles(agent_uid) do
      {:ok, profiles} ->
        profiles
        |> Enum.flat_map(fn {profile, attrs} ->
          case ModelProfiles.profile_capability(profile) do
            {:ok, capability} -> selector_entries(agent_uid, capability, profile, attrs, opts)
            {:error, _reason} -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp selector_entries(_agent_uid, capability, alias_selector, attrs, opts)
       when is_map(attrs) do
    with %{"provider_id" => provider_id, "model" => model} when is_binary(model) <- attrs,
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- Providers.ensure_capability_supported(provider_kind, capability) do
      explicit_selector = "#{provider.provider_id}/#{model}"

      [model_entry(alias_selector, explicit_selector, capability, provider_kind, model)]
      |> maybe_add_explicit_entry(explicit_selector, capability, provider_kind, model, opts)
    else
      _reason -> []
    end
  end

  defp selector_entries(_agent_uid, _capability, _alias_selector, _attrs, _opts), do: []

  # The public `/models` contract must support both alias selectors (`primary`)
  # and explicit selectors (`provider/model`). Agent-facing calls get both;
  # admin catalog calls skip aliases because aliases are agent-local names.
  defp maybe_add_explicit_entry(
         entries,
         explicit_selector,
         capability,
         provider_kind,
         model,
         opts
       ) do
    explicit_entry =
      model_entry(explicit_selector, explicit_selector, capability, provider_kind, model)

    case Keyword.get(opts, :include_aliases?, true) do
      true -> [explicit_entry | entries]
      false -> [explicit_entry]
    end
  end

  defp model_entry(selector, canonical_slug, capability, provider_kind, model) do
    architecture = architecture(capability)

    %{
      "id" => selector,
      "canonical_slug" => canonical_slug,
      "name" => model_name(selector, model),
      "description" => "#{provider_kind.label} #{capability} model #{model}.",
      "created" => 0,
      "architecture" => architecture,
      "pricing" => zero_pricing(),
      "context_length" => 0,
      "top_provider" => %{
        "is_moderated" => false,
        "context_length" => 0,
        "max_completion_tokens" => nil
      },
      "supported_parameters" => supported_parameters(capability, provider_kind),
      "default_parameters" => nil,
      "per_request_limits" => nil,
      "supported_voices" => nil,
      "expiration_date" => nil,
      "knowledge_cutoff" => nil,
      "links" => %{}
    }
  end

  defp model_name(selector, model) do
    case selector == model or String.ends_with?(selector, "/#{model}") do
      true -> model
      false -> selector
    end
  end

  defp architecture("embedding") do
    %{
      "input_modalities" => ["text"],
      "output_modalities" => ["embeddings"],
      "modality" => "text->embeddings",
      "instruct_type" => nil,
      "tokenizer" => nil
    }
  end

  defp architecture(_capability) do
    %{
      "input_modalities" => ["text"],
      "output_modalities" => ["text"],
      "modality" => "text->text",
      "instruct_type" => nil,
      "tokenizer" => nil
    }
  end

  defp zero_pricing do
    %{
      "prompt" => "0",
      "completion" => "0",
      "request" => "0",
      "image" => "0"
    }
  end

  defp supported_parameters("embedding", provider_kind) do
    Enum.uniq(
      ["input", "dimensions", "encoding_format"] ++ provider_kind.runtime_provider_option_keys
    )
  end

  defp supported_parameters("rerank", provider_kind) do
    Enum.uniq(["query", "documents", "top_n"] ++ provider_kind.runtime_provider_option_keys)
  end

  defp supported_parameters(_capability, provider_kind) do
    Enum.uniq(@base_supported_parameters ++ provider_kind.runtime_provider_option_keys)
  end

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
        Enum.filter(entries, &(Map.get(&1, "context_length", 0) >= minimum))

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
    Enum.sort_by(entries, &Map.get(&1, "context_length", 0), :desc)
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
end
