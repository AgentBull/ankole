defmodule AnkoleWeb.Assets do
  @moduledoc """
  Resolves Vite-managed SPA entry assets for Phoenix-rendered shells.

  Two modes, decided by the `:dev_server` config key:

    * Dev — point `<script>` tags straight at the running Vite dev server so HMR
      and React Fast Refresh work.
    * Prod — read the build manifest written by `vite build` and emit the
      hashed, cache-busted asset URLs (plus their CSS and preloads).

  The shell HTML never hardcodes asset paths; it always asks here.
  """

  # The three SPA bundles the shell can mount. `entry` is a build identity, not
  # user input, so an unknown value is a programmer error (it raises below).
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

    # Order is load-bearing: React Fast Refresh requires the refresh runtime
    # preamble to install its global hooks BEFORE the Vite client and the entry
    # module load. Reordering these breaks Fast Refresh (or crashes the entry).
    [
      react_refresh_preamble_tag(base_url),
      module_script_tag("#{base_url}/@vite/client"),
      module_script_tag("#{base_url}/entrypoints/#{entry}.tsx")
    ]
  end

  defp manifest_entry_tags(entry) do
    manifest = read_manifest()

    # A production entry needs its own hashed JS plus the CSS and shared chunks
    # Vite split out of it. We walk the manifest's `imports` graph to gather both
    # so the first paint isn't missing styles or blocked on lazily-discovered chunks.
    case manifest_entry(manifest, entry) do
      %{"file" => file} = chunk ->
        [
          chunk |> manifest_css(manifest) |> Enum.map(&stylesheet_tag/1),
          chunk |> manifest_imports(manifest) |> Enum.map(&modulepreload_tag/1),
          module_script_tag(asset_path(file))
        ]

      # A missing entry means the JS build is stale or never ran — fail loudly at
      # render time rather than serving a blank shell.
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

  # Vite keys entries by source path, but that path can vary across Vite versions
  # and configs. Try the well-known keys first, then fall back to scanning for the
  # entry chunk whose `name` matches — so the lookup survives manifest layout drift.
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

  # Recurse the import graph collecting every chunk's CSS. `seen` guards against
  # the cycles Vite chunk graphs can contain (A imports B imports A) so this
  # terminates; results are de-duped at the end.
  defp collect_manifest_css(chunk, manifest, seen) do
    chunk
    |> Map.get("imports", [])
    |> Enum.reduce({Map.get(chunk, "css", []) |> Enum.reverse(), seen}, fn key, {acc, seen} ->
      with false <- MapSet.member?(seen, key),
           %{} = import_chunk <- Map.get(manifest, key) do
        seen = MapSet.put(seen, key)
        {css, seen} = collect_manifest_css(import_chunk, manifest, seen)
        {Enum.reverse(css, acc), seen}
      else
        _missing_or_seen -> {acc, seen}
      end
    end)
    |> then(fn {css, seen} -> {css |> Enum.reverse() |> Enum.uniq(), seen} end)
  end

  # Same cycle-guarded walk, but collecting the JS files of imported chunks so
  # they can be `modulepreload`-ed alongside the entry.
  defp collect_manifest_import_files(chunk, manifest, seen) do
    chunk
    |> Map.get("imports", [])
    |> Enum.reduce({[], seen}, fn key, {acc, seen} ->
      with false <- MapSet.member?(seen, key),
           %{"file" => file} = import_chunk <- Map.get(manifest, key) do
        seen = MapSet.put(seen, key)
        {nested_files, seen} = collect_manifest_import_files(import_chunk, manifest, seen)
        {Enum.reverse([file | nested_files], acc), seen}
      else
        _missing_or_seen -> {acc, seen}
      end
    end)
    |> then(fn {files, seen} -> {files |> Enum.reverse() |> Enum.uniq(), seen} end)
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

  # Hand-rolled copy of the preamble `@vitejs/plugin-react` normally injects into
  # the HTML. Because Phoenix renders the shell (not Vite's index.html), we must
  # emit it ourselves; without it React Fast Refresh has no global hooks to call.
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
