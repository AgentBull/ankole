defmodule Ankole.I18n.Loader do
  @moduledoc """
  Loads TOML locale catalogs from disk.

  The loader only deals with release-owned files and the stable mapping from a
  filename to a locale id. It does not read AppConfigure or user input; runtime
  availability is enforced later by `Ankole.I18n.Catalog`.
  """

  alias Ankole.I18n.Normalizer

  @type locale_entry :: %{
          messages: %{String.t() => String.t()},
          meta: map()
        }

  @doc """
  Loads every `*.toml` locale file in `dir`.

  The returned map is deterministic because files are listed in stable order.
  `:toml_spec` is injectable for tests that need to pin parser behavior.
  """
  @spec load_all(Path.t(), keyword()) :: %{String.t() => locale_entry()}
  def load_all(dir, opts \\ []) when is_binary(dir) do
    spec = Keyword.get(opts, :toml_spec, :"1.1.0")

    dir
    |> list_toml_files()
    |> Map.new(fn path -> {locale_id_from_path(path), parse_file(path, spec)} end)
  end

  @doc """
  Lists locale TOML files in stable order.

  A missing directory returns an empty list. Catalog startup can then use the
  same degraded path as an empty release instead of forcing filesystem handling
  into this small loader.
  """
  @spec list_toml_files(Path.t()) :: [Path.t()]
  def list_toml_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns the locale id represented by a TOML filename.

  Locale ids stay as strings so release filenames never create runtime atoms.
  """
  @spec locale_id_from_path(Path.t()) :: String.t()
  def locale_id_from_path(path) do
    Path.basename(path, ".toml")
  end

  # Parse errors include the source path because catalog problems are usually
  # fixed by editing release files, not by changing runtime code.
  defp parse_file(path, spec) do
    raw = File.read!(path)

    case TomlElixir.decode(raw, spec: spec) do
      {:ok, decoded} ->
        Normalizer.normalize(decoded, file: path)

      {:error, exception} ->
        raise Normalizer.Error,
          file: path,
          reason: "TOML parse error; #{Exception.message(exception)}"
    end
  end
end
