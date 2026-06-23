defmodule AnkoleWeb.Assets do
  @moduledoc """
  Resolves Vite-managed SPA entry assets for Phoenix-rendered shells.
  """

  @valid_entries ~w(auth console setup)

  @doc "Returns stylesheet and script tags for a named webapp entry."
  @spec entry_tags(Plug.Conn.t(), String.t()) :: iodata()
  def entry_tags(%Plug.Conn{} = _conn, entry) when entry in @valid_entries do
    case dev_server() do
      nil -> manifest_entry_tags(entry)
      base_url -> dev_entry_tags(base_url, entry)
    end
  end

  defp dev_entry_tags(base_url, entry) do
    base_url = String.trim_trailing(base_url, "/")

    [
      react_refresh_preamble_tag(base_url),
      module_script_tag("#{base_url}/@vite/client"),
      module_script_tag("#{base_url}/entrypoints/#{entry}.tsx")
    ]
  end

  defp manifest_entry_tags(entry) do
    manifest = read_manifest()

    case manifest_entry(manifest, entry) do
      %{"file" => file} = chunk ->
        [
          chunk |> manifest_css(manifest) |> Enum.map(&stylesheet_tag/1),
          chunk |> manifest_imports(manifest) |> Enum.map(&modulepreload_tag/1),
          module_script_tag(asset_path(file))
        ]

      _ ->
        raise ArgumentError, "Vite manifest does not contain entry #{inspect(entry)}"
    end
  end

  defp read_manifest do
    path = manifest_path()

    case File.read(path) do
      {:ok, json} ->
        Ankole.JSON.decode!(json)

      {:error, reason} ->
        raise "Could not read Vite manifest at #{path}: #{:file.format_error(reason)}"
    end
  end

  defp manifest_entry(manifest, entry) do
    direct_keys = [entry, "entrypoints/#{entry}.tsx"]

    Enum.find_value(direct_keys, &Map.get(manifest, &1)) ||
      Enum.find_value(manifest, fn
        {_key, %{"isEntry" => true, "name" => ^entry} = chunk} -> chunk
        _entry -> nil
      end)
  end

  defp manifest_css(chunk, manifest) do
    {css, _seen} = collect_manifest_css(chunk, manifest, MapSet.new())

    Enum.map(css, &asset_path/1)
  end

  defp manifest_imports(chunk, manifest) do
    {files, _seen} = collect_manifest_import_files(chunk, manifest, MapSet.new())

    Enum.map(files, &asset_path/1)
  end

  defp collect_manifest_css(chunk, manifest, seen) do
    chunk
    |> Map.get("imports", [])
    |> Enum.reduce({Map.get(chunk, "css", []), seen}, fn key, {acc, seen} ->
      with false <- MapSet.member?(seen, key),
           %{} = import_chunk <- Map.get(manifest, key) do
        seen = MapSet.put(seen, key)
        {css, seen} = collect_manifest_css(import_chunk, manifest, seen)
        {acc ++ css, seen}
      else
        _missing_or_seen -> {acc, seen}
      end
    end)
    |> then(fn {css, seen} -> {Enum.uniq(css), seen} end)
  end

  defp collect_manifest_import_files(chunk, manifest, seen) do
    chunk
    |> Map.get("imports", [])
    |> Enum.reduce({[], seen}, fn key, {acc, seen} ->
      with false <- MapSet.member?(seen, key),
           %{"file" => file} = import_chunk <- Map.get(manifest, key) do
        seen = MapSet.put(seen, key)
        {nested_files, seen} = collect_manifest_import_files(import_chunk, manifest, seen)
        {acc ++ [file | nested_files], seen}
      else
        _missing_or_seen -> {acc, seen}
      end
    end)
    |> then(fn {files, seen} -> {Enum.uniq(files), seen} end)
  end

  defp manifest_path do
    __MODULE__
    |> config()
    |> Keyword.get(
      :manifest_path,
      Application.app_dir(:ankole, "priv/static/assets/manifest.json")
    )
  end

  defp dev_server do
    __MODULE__
    |> config()
    |> Keyword.get(:dev_server)
  end

  defp config(module), do: Application.get_env(:ankole, module, [])

  defp asset_path(path), do: ["/assets/", path]

  defp react_refresh_preamble_tag(base_url) do
    [
      ~s(<script type="module">\n),
      ~s(import RefreshRuntime from '),
      base_url,
      ~s(/@react-refresh'\n),
      ~s|RefreshRuntime.injectIntoGlobalHook(window)\n|,
      ~s|window.$RefreshReg$ = () => {}\n|,
      ~s|window.$RefreshSig$ = () => (type) => type\n|,
      ~s|window.__vite_plugin_react_preamble_installed__ = true\n|,
      ~s(</script>\n)
    ]
  end

  defp stylesheet_tag(href), do: [~s(<link rel="stylesheet" href="), href, ~s(">\n)]

  defp modulepreload_tag(href),
    do: [~s(<link rel="modulepreload" crossorigin="anonymous" href="), href, ~s(">\n)]

  defp module_script_tag(src),
    do: [~s(<script type="module" crossorigin="anonymous" src="), src, ~s("></script>\n)]
end
