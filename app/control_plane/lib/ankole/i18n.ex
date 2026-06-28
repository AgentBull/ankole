defmodule Ankole.I18n do
  @moduledoc """
  Public API for Ankole translation and localization.

  The module keeps the caller-facing contract small: callers pass dotted keys and
  MF2 bindings, while catalog loading, fallback order, and Localize integration
  stay behind this boundary. UI and IM paths should usually call `t/3`; callers
  that must stop on missing or invalid text should call `translate/3`.
  """

  require Logger

  alias Ankole.I18n.Config
  alias Ankole.I18n.Resolver

  @type key :: String.t()
  @type bindings :: map() | keyword()
  @type locale :: String.t() | atom() | Localize.LanguageTag.t()
  @type opts :: [locale: locale(), scope: String.t()]

  @doc """
  Translates `key` and returns a string.

  Missing keys and format errors degrade to visible strings and are logged. This
  keeps user-facing surfaces debuggable: a literal key or MF2 source is easier to
  notice than a blank label.
  """
  @spec t(key(), bindings(), opts()) :: String.t()
  def t(key, bindings \\ %{}, opts \\ []) when is_binary(key) do
    full_key = apply_scope(key, opts)
    locale = locale_from_opts(opts)

    case Resolver.lookup(full_key, locale) do
      nil ->
        Logger.error("i18n missing",
          event: :i18n_missing,
          key: full_key,
          locale: locale,
          domain: :i18n
        )

        full_key

      {^locale, message} ->
        format_or_fallback(message, bindings, locale, full_key)

      {resolved, message} ->
        Logger.warning("i18n fallback",
          event: :i18n_fallback,
          key: full_key,
          requested_locale: locale,
          resolved_locale: resolved,
          domain: :i18n
        )

        format_or_fallback(message, bindings, resolved, full_key)
    end
  end

  @doc """
  Translates `key` and returns a tagged success or error.

  This variant avoids the visible-degradation behavior in `t/3`. It is intended
  for call sites where rendering a fallback string would be worse than returning
  an error, such as an external side-effect boundary.
  """
  @spec translate(key(), bindings(), opts()) ::
          {:ok, String.t()} | {:error, Exception.t()}
  def translate(key, bindings \\ %{}, opts \\ []) when is_binary(key) do
    full_key = apply_scope(key, opts)
    locale = locale_from_opts(opts)

    case Resolver.lookup(full_key, locale) do
      nil ->
        {:error, %KeyError{key: full_key, term: :i18n_catalog}}

      {resolved, message} ->
        Localize.Message.format(message, bindings, locale: resolved)
    end
  end

  @doc """
  Returns the application-wide default locale.
  """
  @spec default_locale() :: Localize.LanguageTag.t()
  defdelegate default_locale, to: Localize

  @doc """
  Returns the configured default locale id.

  Browser/setup surfaces need the persisted catalog id, while
  `default_locale/0` returns Localize's process-wide language tag.
  """
  @spec configured_default_locale() :: {:ok, String.t()} | {:error, term()}
  def configured_default_locale, do: Config.default_locale()

  @doc """
  Persists and applies the application-wide default locale.

  The public write path validates against the currently loaded catalog before it
  touches AppConfigure. Direct AppConfigure writes may store any non-empty locale
  id, but reload/startup still rejects ids that are not loaded.
  """
  @spec put_default_locale(locale()) :: {:ok, String.t()} | {:error, term()}
  def put_default_locale(locale) do
    with {:ok, loaded_locale} <- loaded_locale(locale),
         {:ok, persisted} <- Config.put_default_locale(loaded_locale),
         :ok <- reload() do
      {:ok, persisted}
    end
  end

  @doc """
  Returns the current process locale.
  """
  @spec get_locale() :: Localize.LanguageTag.t()
  defdelegate get_locale, to: Localize

  @doc """
  Sets the current process locale after validating it is loaded.

  Localize can negotiate language tags, but Ankole keeps locale ids tied to
  application-owned catalog files. Validation here prevents a process from
  silently switching to a locale that Ankole cannot render.
  """
  @spec put_locale(locale()) :: {:ok, Localize.LanguageTag.t()} | {:error, Exception.t()}
  def put_locale(locale) do
    with {:ok, loaded_locale} <- loaded_locale(locale),
         {:ok, tag} <- language_tag_for_loaded_locale(loaded_locale) do
      Localize.put_locale(tag)
    end
  end

  @doc """
  Runs `fun` under one validated process locale.

  This is mostly useful for tests and offline rendering. Request and browser
  paths use the installation default locale instead of per-request negotiation.
  """
  @spec with_locale(locale(), (-> result)) :: result | {:error, Exception.t()} when result: term()
  def with_locale(locale, fun) when is_function(fun, 0) do
    with {:ok, loaded_locale} <- loaded_locale(locale),
         {:ok, tag} <- language_tag_for_loaded_locale(loaded_locale) do
      Localize.with_locale(tag, fun)
    end
  end

  @doc """
  Re-applies the effective AppConfigure default locale.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload, do: Ankole.I18n.Catalog.reload()

  @doc """
  Re-scans locale TOML files and applies the effective default locale.
  """
  @spec reload_locales() :: :ok | {:error, term()}
  def reload_locales, do: Ankole.I18n.Catalog.reload_locales()

  @doc """
  Lists loaded locale ids.
  """
  @spec available_locales() :: [String.t()]
  def available_locales, do: Resolver.loaded_list()

  @doc """
  Applies an optional dotted-key scope to an I18n key.
  """
  @spec apply_scope(String.t(), keyword()) :: String.t()
  def apply_scope(key, opts) do
    case Keyword.get(opts, :scope) do
      nil -> leading_dot_key(key, nil)
      scope when is_binary(scope) -> leading_dot_key(key, scope)
    end
  end

  @doc """
  Returns the normalized Ankole locale id from translation options.

  Unknown option values fall back to the process locale so a bad optional value
  does not crash template rendering.
  """
  @spec locale_from_opts(keyword()) :: String.t()
  def locale_from_opts(opts) do
    case Keyword.get(opts, :locale) do
      nil -> Resolver.language_tag_to_locale(Localize.get_locale())
      %Localize.LanguageTag{} = tag -> locale_from_language_tag(tag)
      locale when is_atom(locale) -> Atom.to_string(locale)
      locale when is_binary(locale) -> locale
      _locale -> Resolver.language_tag_to_locale(Localize.get_locale())
    end
  end

  @doc """
  Returns the Ankole locale id for a locale value.

  This is the public facade for rendering boundaries that need ids such as
  `<html lang>` but should not depend on the catalog resolver internals.
  """
  @spec locale_id(locale()) :: String.t()
  def locale_id(%Localize.LanguageTag{} = tag), do: locale_from_language_tag(tag)
  def locale_id(locale) when is_atom(locale), do: Atom.to_string(locale)
  def locale_id(locale) when is_binary(locale), do: locale

  # A leading dot means "relative to the supplied scope". This keeps the helper
  # compatible with legacy call sites without making scoped helpers a separate
  # public API.
  defp leading_dot_key("." <> rest, nil), do: rest
  defp leading_dot_key("." <> rest, scope), do: "#{scope}.#{rest}"
  defp leading_dot_key(key, nil), do: key
  defp leading_dot_key(key, scope), do: "#{scope}.#{key}"

  # Localize tracks both the user-requested tag and the CLDR tag it can support.
  # We prefer the exact loaded Ankole catalog id before falling back to either
  # Localize field.
  defp locale_from_language_tag(tag) do
    Resolver.exact_loaded_locale(tag, Resolver.loaded()) ||
      to_string(tag.requested_locale_id || tag.cldr_locale_id)
  end

  # Ankole treats loaded catalog ids as the real availability set. This is why
  # `put_locale/1` and `put_default_locale/1` do not accept arbitrary valid BCP 47
  # tags.
  defp loaded_locale(locale) do
    case Resolver.exact_loaded_locale(locale, Resolver.loaded()) do
      nil -> {:error, unknown_locale_error(locale)}
      loaded_locale -> {:ok, loaded_locale}
    end
  end

  # Localize still owns process/default locale storage, so loaded catalog ids must
  # be converted back to LanguageTag structs before writing them into Localize.
  defp language_tag_for_loaded_locale(locale) do
    locale
    |> Localize.LanguageTag.new()
    |> case do
      {:ok, %Localize.LanguageTag{cldr_locale_id: id} = tag} when is_atom(id) ->
        {:ok, tag}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp unknown_locale_error(locale) do
    %ArgumentError{
      message:
        "locale #{inspect(locale)} is not loaded. " <>
          "Available locales: #{inspect(available_locales())}"
    }
  end

  # Formatting errors usually mean a missing binding or invalid caller-provided
  # value. Returning the raw MF2 source preserves a visible failure without
  # crashing render paths.
  defp format_or_fallback(message, bindings, locale, full_key) do
    case Localize.Message.format(message, bindings, locale: locale) do
      {:ok, formatted} ->
        formatted

      {:error, reason} ->
        Logger.error("i18n format error",
          event: :i18n_format_error,
          key: full_key,
          locale: locale,
          reason: reason,
          domain: :i18n
        )

        message
    end
  end
end
