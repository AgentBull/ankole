defmodule Ankole.I18n.Loader do
  @moduledoc """
  Loads source or generated locale catalogs from disk.

  The loader only deals with application-owned files and the stable mapping from
  a filename to a locale id. It does not read AppConfigure or user input;
  runtime availability is enforced later by `Ankole.I18n.Catalog`.
  """

  alias Ankole.I18n.Normalizer

  @type locale_entry :: %{
          messages: %{String.t() => String.t()},
          meta: map()
        }

  @doc """
  Loads every `*.toml` or generated `*.json` locale file in `dir`.

  The returned map is deterministic because files are listed in stable order.
  `:toml_spec` is injectable for tests that need to pin parser behavior.
  """
  @spec load_all(Path.t(), keyword()) :: %{String.t() => locale_entry()}
  def load_all(dir, opts \\ []) when is_binary(dir) do
    spec = Keyword.get(opts, :toml_spec, :"1.1.0")

    dir
    |> list_catalog_files()
    |> Map.new(fn path -> {locale_id_from_path(path), parse_file(path, spec)} end)
  end

  @doc """
  Lists locale catalog files in stable order.

  A missing directory returns an empty list. Catalog startup can then use the
  same degraded path as an empty catalog instead of forcing filesystem handling
  into this small loader.
  """
  @spec list_catalog_files(Path.t()) :: [Path.t()]
  def list_catalog_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, [".toml", ".json"]))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns the locale id represented by a TOML filename.

  Locale ids stay as strings so catalog filenames never create runtime atoms.
  """
  @spec locale_id_from_path(Path.t()) :: String.t()
  def locale_id_from_path(path) do
    path |> Path.basename() |> Path.rootname()
  end

  # Parse errors include the source path because catalog problems are usually
  # fixed by editing catalog files, not by changing runtime code.
  defp parse_file(path, spec) do
    raw = File.read!(path)

    result =
      if Path.extname(path) == ".json",
        do: Ankole.JSON.decode(raw),
        else: TomlElixir.decode(raw, spec: spec)

    case result do
      {:ok, decoded} ->
        Normalizer.normalize(decoded, file: path)

      {:error, exception} ->
        raise Normalizer.Error,
          file: path,
          reason: "Catalog parse error; #{inspect(exception)}"
    end
  end
end
