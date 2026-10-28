defmodule Ankole.I18n.Config do
  @moduledoc """
  AppConfigure definitions owned by the I18n subsystem.

  The definition validates the active locale against the available catalogs.
  Startup validation reads release catalog filenames before Catalog starts.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @default_locale "en-US"
  @default_locale_key "i18n.default_locale"
  @default_locales_dir "../locales"

  @doc """
  Returns the release fallback locale id (`"en-US"`).
  """
  @spec release_default_locale() :: String.t()
  def release_default_locale, do: @default_locale

  @doc """
  Returns the declared AppConfigure definition for a Pod's default locale.

  Generic AppConfigure writes use the same catalog availability check as the
  dedicated locale UI.
  """
  @spec default_locale_definition() :: Definition.t()
  def default_locale_definition do
    AppConfigure.define(
      scope: :pod,
      key: @default_locale_key,
      encrypted: false,
      schema: Schema.new(&validate_locale/1),
      default_value: @default_locale,
      description: "Default locale used when rendering Ankole text in this Pod."
    )
  end

  defp validate_locale(locale) do
    loaded = Ankole.I18n.Resolver.loaded()

    available =
      if map_size(loaded) > 0 do
        loaded
      else
        locales_dir()
        |> Ankole.I18n.Loader.list_catalog_files()
        |> Map.new(&{Ankole.I18n.Loader.locale_id_from_path(&1), true})
      end

    case Ankole.I18n.Resolver.exact_loaded_locale(locale, available) do
      nil -> {:error, :unavailable_locale}
      canonical -> {:ok, canonical}
    end
  end

  @doc """
  Returns all AppConfigure definitions owned by I18n.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: [default_locale_definition()]

  @doc """
  Reads the current Pod's effective default locale through AppConfigure.
  """
  @spec default_locale() :: {:ok, String.t()} | {:error, term()}
  def default_locale do
    AppConfigure.get(default_locale_definition())
  end

  @doc """
  Persists the current Pod's default locale through AppConfigure.

  Use `Ankole.I18n.put_default_locale/1` to validate the loaded catalog before
  writing.
  """
  @spec put_default_locale(String.t()) :: {:ok, String.t()} | {:error, term()}
  def put_default_locale(locale) do
    AppConfigure.put_tenant_by_key(default_locale_definition().key, locale)
  end

  @doc false
  @spec put_default_locale_in_tx(String.t()) ::
          {:ok, AppConfigure.committed_write()} | {:error, term()}
  def put_default_locale_in_tx(locale) do
    AppConfigure.put_tenant_by_key_in_tx(default_locale_definition().key, locale)
  end

  @doc """
  Returns the directory containing shared locale catalogs.

  The default points at `app/locales`, outside the Phoenix application, so
  control-plane and webapp code can share the same catalog root. Relative paths
  prefer the release application directory and fall back to the current working
  directory. The fallback keeps local tests and source-tree runs simple before a
  release layout exists.
  """
  @spec locales_dir() :: Path.t()
  def locales_dir do
    :ankole
    |> Application.get_env(:i18n, [])
    |> Keyword.get(:locales_dir, @default_locales_dir)
    |> expand_locales_dir()
  end

  # Release builds should resolve relative paths inside the application package.
  # Source-tree runs and tests may not have that directory yet, so they fall back
  # to the current working directory.
  defp expand_locales_dir(dir) do
    case Path.type(dir) do
      :absolute ->
        dir

      _relative ->
        app_dir = Application.app_dir(:ankole, dir)
        if File.dir?(app_dir), do: app_dir, else: Path.expand(dir, File.cwd!())
    end
  end
end
