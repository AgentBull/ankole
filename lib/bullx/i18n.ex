defmodule BullX.I18n do
  @moduledoc """
  Public API for BullX's translation and localization subsystem.

  Core responsibilities:

  * **Key lookup.** `t/3` and `translate/3` take a dotted key,
    resolve it through the locale fallback chain, and format the
    resulting MF2 message.

  * **Locale lifecycle.** Under the RFC 0007 "locale is global"
    assumption, the default locale is set once at boot from
    `BullX.Config.I18n.i18n_default_locale!/0`. `put_locale/1`,
    `with_locale/2`, `get_locale/0`, `default_locale/0`, and
    `put_default_locale/1` are retained for tests and offline
    rendering. BullX still uses `Localize` for storage, but
    validates the requested locale against the loaded catalog first
    so process/default locale never silently negotiate to a
    different language.

  * **Scope macro.** `use BullX.I18n, scope: "some.scope"` injects
    a module-local `t/1,2,3` whose key is concatenated with the
    scope at compile time.

  * **Catalog reload.** `reload/0` re-syncs the default locale from
    `BullX.Config`; it does not rescan TOML files. The catalog is
    (re)loaded at boot or on a dev-mode filesystem event.

  See `rfcs/plans/0007_I18n.md` for the full design.
  """

  require Logger

  alias BullX.I18n.Resolver

  @type key :: String.t()
  @type bindings :: map() | Keyword.t()
  @type opts :: [locale: atom(), scope: String.t()]
  @type locale :: atom() | String.t() | Localize.LanguageTag.t()

  @doc """
  Translate `key`. Returns the formatted string.

  Missing keys and MF2 format errors degrade per §5.4 and never
  raise: the caller always receives a string.

  """
  @spec t(key(), bindings(), opts()) :: String.t()
  def t(key, bindings \\ %{}, opts \\ []) do
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
  Translate `key`. Returns `{:ok, string}` or `{:error, exception}`
  without logging a missing/format-error event.

  Use this variant when a caller must distinguish "degraded" from
  "successful" — for example an external side-effect boundary that
  should not proceed if only a key literal is available.
  """
  @spec translate(key(), bindings(), opts()) ::
          {:ok, String.t()} | {:error, Exception.t()}
  def translate(key, bindings \\ %{}, opts \\ []) do
    full_key = apply_scope(key, opts)
    locale = locale_from_opts(opts)

    case Resolver.lookup(full_key, locale) do
      nil ->
        {:error, %KeyError{key: full_key, term: :i18n_catalog}}

      {resolved, message} ->
        case Localize.Message.format(message, bindings, locale: resolved) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Returns the application-wide default locale as a `LanguageTag`.
  """
  @spec default_locale() :: Localize.LanguageTag.t()
  defdelegate default_locale, to: Localize

  @spec put_default_locale(locale()) ::
          {:ok, Localize.LanguageTag.t()} | {:error, Exception.t()}
  def put_default_locale(locale) do
    with {:ok, tag} <- language_tag_for_loaded_locale(locale) do
      Localize.put_default_locale(tag)
    end
  end

  @spec get_locale() :: Localize.LanguageTag.t()
  defdelegate get_locale, to: Localize

  @spec put_locale(locale()) ::
          {:ok, Localize.LanguageTag.t()} | {:error, Exception.t()}
  def put_locale(locale) do
    with {:ok, tag} <- language_tag_for_loaded_locale(locale) do
      Localize.put_locale(tag)
    end
  end

  @spec with_locale(locale(), (-> result)) :: result | {:error, Exception.t()} when result: any()
  def with_locale(locale, fun) when is_function(fun, 0) do
    with {:ok, tag} <- language_tag_for_loaded_locale(locale) do
      Localize.with_locale(tag, fun)
    end
  end

  @doc """
  Re-sync the default locale from `BullX.Config.I18n`.

  Does not re-scan TOML files. Use this after an operator has
  changed `bullx.i18n_default_locale` (via `BullX.Config.put/2` or
  the `BULLX_I18N_DEFAULT_LOCALE` env var) to apply the new value
  without a restart.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload, do: BullX.I18n.Catalog.reload()

  @doc """
  List the locales currently loaded from `priv/locales/*.toml`.
  """
  @spec available_locales() :: [atom()]
  def available_locales, do: Resolver.loaded_list()

  @doc false
  def apply_scope(key, opts) do
    case Keyword.get(opts, :scope) do
      nil -> leading_dot_key(key, nil)
      scope when is_binary(scope) -> leading_dot_key(key, scope)
    end
  end

  defp leading_dot_key("." <> rest, nil), do: rest
  defp leading_dot_key("." <> rest, scope), do: "#{scope}.#{rest}"
  defp leading_dot_key(key, nil), do: key
  defp leading_dot_key(key, scope), do: "#{scope}.#{key}"

  @doc false
  def locale_from_opts(opts) do
    case Keyword.get(opts, :locale) do
      nil -> Resolver.language_tag_to_locale(Localize.get_locale())
      locale when is_atom(locale) -> locale
    end
  end

  defp language_tag_for_loaded_locale(locale) do
    with {:ok, loaded_locale} <- loaded_locale(locale),
         {:ok, tag} <- loaded_locale_tag(loaded_locale) do
      {:ok, tag}
    end
  end

  defp loaded_locale(%Localize.LanguageTag{} = tag) do
    case exact_loaded_locale(tag.requested_locale_id) || exact_loaded_locale(tag.cldr_locale_id) do
      nil -> {:error, unknown_locale_error(tag)}
      locale -> {:ok, locale}
    end
  end

  defp loaded_locale(locale) when is_atom(locale) do
    if Map.has_key?(Resolver.loaded(), locale) do
      {:ok, locale}
    else
      {:error, unknown_locale_error(locale)}
    end
  end

  defp loaded_locale(locale) when is_binary(locale) do
    case exact_loaded_locale(locale) do
      nil -> {:error, unknown_locale_error(locale)}
      loaded_locale -> {:ok, loaded_locale}
    end
  end

  defp loaded_locale(locale), do: {:error, unknown_locale_error(locale)}

  defp loaded_locale_tag(locale) do
    locale
    |> Atom.to_string()
    |> Localize.LanguageTag.new()
    |> case do
      {:ok, %Localize.LanguageTag{cldr_locale_id: id} = tag} when is_atom(id) ->
        {:ok, tag}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp exact_loaded_locale(locale) when is_atom(locale) do
    if Map.has_key?(Resolver.loaded(), locale), do: locale
  end

  defp exact_loaded_locale(locale) when is_binary(locale) do
    Resolver.loaded()
    |> Map.keys()
    |> Enum.find(fn loaded_locale ->
      Atom.to_string(loaded_locale) == locale
    end)
  end

  defp exact_loaded_locale(_locale), do: nil

  defp unknown_locale_error(locale) do
    available =
      available_locales()
      |> Enum.map(&Atom.to_string/1)

    %ArgumentError{
      message: "locale #{inspect(locale)} is not loaded. Available locales: #{inspect(available)}"
    }
  end

  defp format_or_fallback(message, bindings, locale, full_key) do
    case Localize.Message.format(message, bindings, locale: locale) do
      {:ok, formatted} ->
        formatted

      {:error, err} ->
        Logger.error("i18n format error",
          event: :i18n_format_error,
          key: full_key,
          locale: locale,
          reason: err,
          domain: :i18n
        )

        message
    end
  end

  @doc """
  Opt-in macro that injects a scoped `t/1,2,3` into the using
  module.

  ### Example

      defmodule MyLive do
        use BullX.I18n, scope: "some.scope"

        def render(assigns) do
          ~H\"\"\"
          <h1><%= t("title") %></h1>
          \"\"\"
        end
      end
  """
  defmacro __using__(opts) do
    scope = Keyword.get(opts, :scope)

    unless is_binary(scope) or is_nil(scope) do
      raise ArgumentError,
            "use BullX.I18n requires a :scope binary or nil"
    end

    quote do
      @bullx_i18n_scope unquote(scope)

      def t(key, bindings \\ %{}, opts \\ []) do
        opts = Keyword.put(opts, :scope, @bullx_i18n_scope)
        BullX.I18n.t(key, bindings, opts)
      end
    end
  end
end
