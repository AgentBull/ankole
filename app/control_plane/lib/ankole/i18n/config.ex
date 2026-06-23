defmodule Ankole.I18n.Config do
  @moduledoc """
  AppConfigure definitions owned by the I18n subsystem.

  AppConfigure stores the operator-selected locale id as durable runtime
  configuration. It does not scan locale files. Catalog startup and reload own
  the stronger check that the stored id is actually available in the loaded
  release catalog.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @default_locale "en-US"
  @default_locale_key "i18n.default_locale"
  @default_locales_dir "priv/locales"

  @doc """
  Returns the declared AppConfigure definition for the default locale.

  The schema only requires a non-empty string. This is a deliberate boundary:
  saving a choice and proving that the release contains a matching catalog are
  different responsibilities.
  """
  @spec default_locale_definition() :: Definition.t()
  def default_locale_definition do
    AppConfigure.define(
      key: @default_locale_key,
      encrypted: false,
      schema: Schema.non_empty_string(),
      default_value: @default_locale,
      description: "Default locale used when rendering Ankole text."
    )
  end

  @doc """
  Returns all AppConfigure definitions owned by I18n.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: [default_locale_definition()]

  @doc """
  Registers I18n's AppConfigure keys.

  Supervised components may restart, so duplicate registration of the same key
  is treated as already registered.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions(definitions()) do
      :ok -> :ok
      {:error, {:duplicate_key, @default_locale_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the effective default locale through AppConfigure.
  """
  @spec default_locale() :: {:ok, String.t()} | {:error, term()}
  def default_locale do
    with :ok <- ensure_registered(),
         {:ok, locale} <- AppConfigure.get(default_locale_definition()) do
      {:ok, locale}
    end
  end

  @doc """
  Persists the installation-wide default locale through AppConfigure.

  This function is storage-level. Callers that want to apply the locale should use
  `Ankole.I18n.put_default_locale/1`, which validates against the loaded catalog
  before persisting and then reloads Localize.
  """
  @spec put_default_locale(String.t()) :: {:ok, String.t()} | {:error, term()}
  def put_default_locale(locale) do
    with :ok <- ensure_registered(),
         {:ok, persisted} <- AppConfigure.put_global(default_locale_definition(), locale) do
      {:ok, persisted}
    end
  end

  @doc """
  Returns the directory containing server-side locale catalogs.

  Relative paths prefer the release application directory and fall back to the
  current working directory. The fallback keeps local tests and source-tree runs
  simple before a release layout exists.
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
