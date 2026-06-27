defmodule Ankole.I18n.Resolver do
  @moduledoc """
  Fallback-chain construction and catalog lookup for I18n.

  Resolver is the read-optimized projection of the catalog. Translation reads are
  much more frequent than catalog reloads, so catalog maps and fallback-chain
  cache live in `:persistent_term`. The cost is paid on reload, where the system
  already expects a small amount of coordination.
  """

  @messages_prefix {:ankole_i18n, :messages}
  @meta_prefix {:ankole_i18n, :meta}
  @loaded_key {:ankole_i18n, :loaded}
  @chain_cache_key {:ankole_i18n, :chains}
  @default_fallback "en-US"

  @type locale :: String.t()

  @doc """
  Stores one locale catalog in persistent term.

  Each write clears fallback-chain cache because metadata can affect fallback
  order even when the loaded locale set did not change.
  """
  @spec put_catalog(locale(), %{optional(String.t()) => String.t()}, map()) :: :ok
  def put_catalog(locale, messages, meta) when is_binary(locale) do
    :persistent_term.put({@messages_prefix, locale}, messages)
    :persistent_term.put({@meta_prefix, locale}, meta)
    clear_chain_cache()
    :ok
  end

  @doc """
  Removes one locale catalog from persistent term.

  This is called when a release no longer ships a locale file, so stale messages
  cannot survive after `reload_locales/0`.
  """
  @spec drop_catalog(locale()) :: :ok
  def drop_catalog(locale) when is_binary(locale) do
    :persistent_term.erase({@messages_prefix, locale})
    :persistent_term.erase({@meta_prefix, locale})
    clear_chain_cache()
    :ok
  end

  @doc """
  Stores the set of currently loaded locale ids.

  The loaded set is the source of truth for what Ankole can render. Localize may
  understand more tags, but Resolver only returns ids that have catalog files.
  """
  @spec put_loaded([locale()]) :: :ok
  def put_loaded(locales) when is_list(locales) do
    :persistent_term.put(@loaded_key, Map.new(locales, &{&1, true}))
    clear_chain_cache()
    :ok
  end

  @doc """
  Clears memoized fallback chains.

  Chains depend on the loaded set, metadata fallback values, and the Localize
  default locale. Reload paths call this instead of trying to patch individual
  cache entries.
  """
  @spec clear_chain_cache() :: :ok
  def clear_chain_cache do
    :persistent_term.erase(@chain_cache_key)
    :ok
  end

  @doc """
  Returns a map of loaded locale ids.
  """
  @spec loaded() :: %{locale() => true}
  def loaded do
    :persistent_term.get(@loaded_key, %{})
  end

  @doc """
  Returns loaded locale ids in stable order.
  """
  @spec loaded_list() :: [locale()]
  def loaded_list do
    loaded() |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns messages for a locale, if loaded.
  """
  @spec messages(locale()) :: %{String.t() => String.t()} | nil
  def messages(locale) do
    :persistent_term.get({@messages_prefix, locale}, nil)
  end

  @doc """
  Returns normalized metadata for a locale.
  """
  @spec meta(locale()) :: map()
  def meta(locale) do
    :persistent_term.get({@meta_prefix, locale}, %{})
  end

  @doc """
  Resolves `key` in `locale`, including fallback locales.

  The first loaded catalog containing the key wins. Missing keys return `nil` so
  caller-facing APIs can choose between visible degradation and tagged errors.
  """
  @spec lookup(String.t(), locale()) :: {locale(), String.t()} | nil
  def lookup(key, locale) do
    Enum.find_value(fallback_chain(locale), fn candidate ->
      case messages(candidate) do
        nil -> nil
        map -> map |> Map.get(key) |> wrap(candidate)
      end
    end)
  end

  @doc """
  Builds and memoizes the fallback chain for `locale`.

  The chain is cached because render paths can call it often, while changes only
  happen during catalog reloads or default-locale updates.
  """
  @spec fallback_chain(locale()) :: [locale()]
  def fallback_chain(locale) do
    chains = :persistent_term.get(@chain_cache_key, %{})

    case Map.get(chains, locale) do
      nil ->
        chain = build_chain(locale)
        :persistent_term.put(@chain_cache_key, Map.put(chains, locale, chain))
        chain

      chain ->
        chain
    end
  end

  @doc """
  Resolves a Localize language tag to one loaded Ankole locale id.

  This is used by HTML helpers and process-locale reads. It prefers exact loaded
  Ankole ids and falls back to the hard default only when Localize cannot be
  mapped back to a loaded catalog.
  """
  @spec language_tag_to_locale(Localize.LanguageTag.t()) :: locale()
  def language_tag_to_locale(%Localize.LanguageTag{} = tag) do
    loaded = loaded()

    exact_loaded_locale(tag.requested_locale_id, loaded) ||
      exact_loaded_locale(tag.cldr_locale_id, loaded) ||
      @default_fallback
  end

  @doc """
  Finds a loaded locale matching an atom, string, or Localize language tag.

  Accepting atoms keeps compatibility with Localize structs and older test code,
  but the result is always a loaded string id from Ankole's catalog set.
  """
  @spec exact_loaded_locale(term(), %{locale() => true}) :: locale() | nil
  def exact_loaded_locale(%Localize.LanguageTag{} = tag, loaded) do
    exact_loaded_locale(tag.requested_locale_id, loaded) ||
      exact_loaded_locale(tag.cldr_locale_id, loaded)
  end

  def exact_loaded_locale(locale, loaded) when is_atom(locale) do
    exact_loaded_locale(Atom.to_string(locale), loaded)
  end

  def exact_loaded_locale(locale, loaded) when is_binary(locale) do
    if Map.has_key?(loaded, locale), do: locale
  end

  def exact_loaded_locale(_locale, _loaded), do: nil

  defp wrap(nil, _locale), do: nil
  defp wrap(message, locale), do: {locale, message}

  # Fallback is deliberately explicit: requested locale, catalog-declared
  # fallback, Localize default, then hard English default. There is no implicit
  # BCP 47 parent walk yet because the current product story needs predictable
  # catalog-owned fallback, not a general locale engine.
  defp build_chain(locale) do
    loaded = loaded()

    [
      exact_loaded_locale(locale, loaded),
      meta_fallback(locale, loaded),
      default_locale(loaded),
      @default_fallback
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(loaded, &1))
  end

  # Only the catalog's `__meta__.fallback` participates here. This keeps fallback
  # choices reviewable in the same file as the translated messages.
  defp meta_fallback(locale, loaded) do
    case meta(locale) do
      %{fallback: fallback} when is_binary(fallback) -> exact_loaded_locale(fallback, loaded)
      _metadata -> nil
    end
  end

  # Localize owns the current default language tag, but Ankole still maps it back
  # to a loaded catalog id before using it in a fallback chain.
  defp default_locale(loaded) do
    Localize.default_locale()
    |> exact_loaded_locale(loaded)
  end
end
