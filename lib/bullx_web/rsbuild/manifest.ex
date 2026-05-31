defmodule BullXWeb.Rsbuild.Manifest do
  @moduledoc """
  Parser for the Rsbuild asset manifest consumed by Phoenix rendering.

  The manifest maps frontend entry names to emitted JS/CSS files so server-side
  layout code can include the correct bundled assets.
  """

  defmodule Entry do
    @moduledoc "Parsed asset lists for one Rsbuild frontend entry."

    defstruct [
      :name,
      initial_js: [],
      initial_css: [],
      async_js: [],
      async_css: [],
      assets: [],
      html: []
    ]
  end

  def parse(%{"entries" => entries}) when is_map(entries) do
    entries
    |> Enum.reject(fn {name, _entry} -> name == "integrity" end)
    |> Map.new(fn {name, entry} -> {name, parse_entry(name, entry)} end)
  end

  def parse(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> parse()
  end

  def parse({app, path}) when is_atom(app) and is_binary(path) do
    app
    |> Application.app_dir(path)
    |> File.read!()
    |> parse()
  end

  defp parse_entry(name, entry) when is_map(entry) do
    %Entry{
      name: name,
      initial_js: files_from(entry, "initial", "js"),
      initial_css: files_from(entry, "initial", "css"),
      async_js: files_from(entry, "async", "js"),
      async_css: files_from(entry, "async", "css"),
      assets: normalize_files(Map.get(entry, "assets", [])),
      html: normalize_files(Map.get(entry, "html", []))
    }
  end

  defp files_from(entry, group, type) do
    entry
    |> Map.get(group, %{})
    |> Map.get(type, [])
    |> normalize_files()
  end

  defp normalize_files(files) when is_list(files), do: Enum.map(files, &normalize_file/1)

  defp normalize_file("/" <> file), do: file
  defp normalize_file(file), do: file
end
