defmodule Ankole.I18n.Catalog do
  @moduledoc """
  Owns the process that loads Ankole translation catalogs.

  This GenServer is the single write point for runtime catalog state. AppConfigure
  stores the operator's selected locale id, but this module proves that the id is
  backed by a loaded locale file before writing it into Localize. Keeping that
  split avoids a config engine that needs to know about release files.
  """

  use GenServer

  require Logger

  alias Ankole.I18n.Config
  alias Ankole.I18n.Loader
  alias Ankole.I18n.Resolver

  @name __MODULE__

  defstruct [:locales_dir]

  @type t :: %__MODULE__{locales_dir: Path.t()}

  @doc """
  Starts the catalog owner.

  Tests may pass `:locales_dir` to exercise catalogs without changing the
  application environment.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Re-applies the effective default locale from AppConfigure.

  This does not scan files. It is the cheap path used after the stored default
  changes and the loaded catalog set is already current.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(@name, :reload)

  @doc """
  Re-scans locale files and applies the effective default locale.

  This is the heavier path for release/test changes where the TOML files
  themselves may have changed.
  """
  @spec reload_locales() :: :ok | {:error, term()}
  def reload_locales, do: GenServer.call(@name, :reload_locales)

  @doc """
  Re-scans locale files and raises if the catalog cannot be applied.

  The bang form is mainly useful in tests and bootstrapping code where a broken
  catalog should fail immediately.
  """
  @spec reload_locales!() :: :ok
  def reload_locales! do
    :ok = reload_locales()
  end

  @impl true
  def init(opts) do
    locales_dir = Keyword.get(opts, :locales_dir, Config.locales_dir())
    state = %__MODULE__{locales_dir: locales_dir}

    with :ok <- Config.ensure_registered(),
         :ok <- load_catalog(locales_dir),
         :ok <- apply_config_default_locale() do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, apply_config_default_locale(), state}
  end

  @impl true
  def handle_call(:reload_locales, _from, state) do
    result =
      with :ok <- load_catalog(state.locales_dir),
           :ok <- apply_config_default_locale() do
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.warning("Unexpected message in #{__MODULE__}: #{inspect(message)}")
    {:noreply, state}
  end

  # The catalog is loaded from disk before replacing Resolver state. Locale files
  # are release artifacts, so a parse/normalization failure should stop the
  # reload instead of leaving a half-normalized catalog behind.
  defp load_catalog(dir) do
    locales = Loader.load_all(dir)

    if locales == %{} do
      Logger.warning("no locale files found in #{dir}; Ankole.I18n will degrade to key literals",
        domain: :i18n
      )
    end

    ids = Map.keys(locales)
    current = Resolver.loaded() |> Map.keys()

    # Removed files must also disappear from runtime lookup. Otherwise an old
    # translation could survive a release where the catalog was intentionally
    # deleted.
    Enum.each(current -- ids, &Resolver.drop_catalog/1)
    :ok = sync_supported_locales(ids)
    :ok = Resolver.put_loaded(ids)

    Enum.each(locales, fn {locale, %{messages: messages, meta: meta}} ->
      Resolver.put_catalog(locale, messages, meta)
    end)

    :ok
  rescue
    exception -> {:error, exception}
  end

  # AppConfigure only promises a non-empty string. This is the enforcement point
  # where that durable value must match the loaded release catalog.
  defp apply_config_default_locale do
    with {:ok, configured} <- Config.default_locale(),
         {:ok, tag} <- language_tag_for_loaded_locale(configured) do
      {:ok, _tag} = Localize.put_default_locale(tag)
      Resolver.clear_chain_cache()
      :ok
    else
      {:error, %ArgumentError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Localize works with CLDR locale ids, while Ankole keeps BCP 47-like catalog
  # ids from filenames. We synchronize Localize's supported set from the loaded
  # files instead of duplicating that list in configuration.
  defp sync_supported_locales(locale_ids) do
    locale_ids
    |> Enum.map(&language_tag_for_locale_id!/1)
    |> Enum.map(& &1.cldr_locale_id)
    |> Enum.uniq()
    |> Localize.put_supported_locales()
  end

  # A stored default must be exactly available as a loaded Ankole catalog id
  # before Localize receives it. This avoids Localize negotiation hiding a missing
  # translation file.
  defp language_tag_for_loaded_locale(locale) do
    loaded = Resolver.loaded()

    case Resolver.exact_loaded_locale(locale, loaded) do
      nil ->
        {:error, unknown_locale_error(locale, loaded)}

      loaded_locale ->
        loaded_locale
        |> Localize.LanguageTag.new()
        |> case do
          {:ok, %Localize.LanguageTag{cldr_locale_id: id} = tag} when is_atom(id) ->
            {:ok, tag}

          {:error, exception} ->
            {:error, exception}
        end
    end
  end

  # Filenames are release-owned inputs. An invalid locale filename is a release
  # bug, so the loader should fail loudly instead of silently skipping it.
  defp language_tag_for_locale_id!(locale) do
    case Localize.LanguageTag.new(locale) do
      {:ok, %Localize.LanguageTag{cldr_locale_id: id} = tag} when is_atom(id) ->
        tag

      {:error, exception} ->
        raise exception
    end
  end

  # Including the loaded set makes startup and operator recovery actionable when
  # AppConfigure contains a stale value after a catalog change.
  defp unknown_locale_error(locale, loaded) do
    available = loaded |> Map.keys() |> Enum.sort()

    %ArgumentError{
      message:
        "configured i18n.default_locale #{inspect(locale)} is not available. " <>
          "Available locales: #{inspect(available)}"
    }
  end
end
