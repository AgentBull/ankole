defmodule Ankole.I18n do
  @moduledoc """
  Public API for Ankole translation and localization.

  The module keeps the caller-facing contract small: callers pass dotted keys and
  MF2 bindings, while catalog loading, fallback order, and Localize integration
  stay behind this boundary. UI and IM paths call `t/3`.
  """

  alias Ankole.I18n.Config
  alias Ankole.I18n.Resolver
  alias Ankole.Logging

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
        Logging.error("i18n.missing", "i18n missing", %{
          key: full_key,
          locale: locale
        })

        full_key

      {^locale, message} ->
        format_or_fallback(message, bindings, locale, full_key)

      {resolved, message} ->
        Logging.warning("i18n.fallback", "i18n fallback", %{
          key: full_key,
          requested_locale: locale,
          resolved_locale: resolved
        })

        format_or_fallback(message, bindings, resolved, full_key)
    end
  end

  @doc """
  Returns the site default used by shared catalog fallback.
  """
  @spec default_locale() :: Localize.LanguageTag.t()
  defdelegate default_locale, to: Localize

  @doc """
  Returns the configured default locale id.

  Browser/setup surfaces need the persisted catalog id, while
  `default_locale/0` returns Localize's site-wide language tag.
  """
  @spec configured_default_locale() :: {:ok, String.t()} | {:error, term()}
  def configured_default_locale, do: Config.default_locale()

  @doc """
  Persists the current tenant's default locale.

  The public write path validates against the loaded catalog before it touches
  AppConfigure. Tenant writes do not change the shared catalog or site default.
  """
  @spec put_default_locale(locale()) :: {:ok, String.t()} | {:error, term()}
  def put_default_locale(locale) do
    with {:ok, loaded_locale} <- loaded_locale(locale),
         {:ok, persisted} <- Config.put_default_locale(loaded_locale) do
      {:ok, persisted}
    end
  end

  @doc """
  Lists loaded locale ids.
  """
  @spec available_locales() :: [String.t()]
  def available_locales, do: Resolver.loaded_list()

  @doc """
  Matches an `Accept-Language` header or locale tag to a loaded catalog locale.
  """
  @spec negotiate_locale(String.t() | [String.t()] | nil) :: String.t() | nil
  def negotiate_locale(nil), do: nil

  def negotiate_locale(values) when is_list(values) do
    values
    |> Enum.join(",")
    |> negotiate_locale()
  end

  def negotiate_locale(header) when is_binary(header) do
    available = available_locales()
    by_exact = Map.new(available, &{String.downcase(&1), &1})

    by_language =
      Enum.reduce(available, %{}, fn locale, acc ->
        Map.put_new(acc, primary_subtag(locale), locale)
      end)

    header
    |> parse_language_ranges()
    |> Enum.find_value(fn tag ->
      downcased = String.downcase(tag)
      Map.get(by_exact, downcased) || Map.get(by_language, primary_subtag(downcased))
    end)
  end

  def negotiate_locale(_), do: nil

  # Applies an optional dotted-key scope to an I18n key.
  #
  @spec apply_scope(String.t(), keyword()) :: String.t()
  defp apply_scope(key, opts) do
    case Keyword.get(opts, :scope) do
      nil -> leading_dot_key(key, nil)
      scope when is_binary(scope) -> leading_dot_key(key, scope)
    end
  end

  # Returns the normalized Ankole locale id from translation options.
  #
  # Without an explicit locale, translations read the current tenant's effective
  # default. This requires the same tenant context as the work being rendered.
  #
  @spec locale_from_opts(keyword()) :: String.t()
  defp locale_from_opts(opts) do
    case Keyword.get(opts, :locale) do
      nil -> configured_locale!()
      %Localize.LanguageTag{} = tag -> locale_from_language_tag(tag)
      locale when is_atom(locale) -> Atom.to_string(locale)
      locale when is_binary(locale) -> locale
      _locale -> configured_locale!()
    end
  end

  defp leading_dot_key(key, nil), do: key
  defp leading_dot_key(key, scope), do: "#{scope}.#{key}"

  # Localize tracks both the user-requested tag and the CLDR tag it can support.
  # We prefer the exact loaded Ankole catalog id before falling back to either
  # Localize field.
  defp locale_from_language_tag(tag) do
    Resolver.exact_loaded_locale(tag, Resolver.loaded()) ||
      to_string(tag.requested_locale_id || tag.cldr_locale_id)
  end

  defp configured_locale! do
    case Config.default_locale() do
      {:ok, locale} -> locale
      error -> raise ArgumentError, "cannot read the tenant locale: #{inspect(error)}"
    end
  end

  defp loaded_locale(locale) do
    case Resolver.exact_loaded_locale(locale, Resolver.loaded()) do
      nil -> {:error, unknown_locale_error(locale)}
      loaded_locale -> {:ok, loaded_locale}
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
        Logging.error("i18n.format_error", "i18n format error", %{
          key: full_key,
          locale: locale,
          reason: inspect(reason)
        })

        message
    end
  end

  defp parse_language_ranges(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      case parse_language_range(entry) do
        {tag, weight} when tag != "" and tag != "*" and weight > 0.0 -> [{tag, weight, index}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_tag, weight, index} -> {-weight, index} end)
    |> Enum.map(fn {tag, _weight, _index} -> tag end)
  end

  defp parse_language_range(entry) do
    [raw_tag | params] = String.split(entry, ";", trim: true)
    tag = raw_tag |> String.trim() |> String.replace("_", "-")
    {tag, parse_q_weight(params)}
  end

  defp parse_q_weight(params) do
    q_param =
      Enum.find_value(params, fn param ->
        case String.split(param, "=", parts: 2) do
          [key, value] ->
            if String.downcase(String.trim(key)) == "q", do: String.trim(value)

          _ ->
            nil
        end
      end)

    case q_param do
      nil ->
        1.0

      raw ->
        case Float.parse(raw) do
          {weight, ""} when weight >= 0.0 and weight <= 1.0 -> weight
          _ -> 0.0
        end
    end
  end

  defp primary_subtag(tag) do
    tag |> String.split("-", parts: 2) |> hd() |> String.downcase()
  end
end
