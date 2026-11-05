defmodule AnkoleWeb.AssetsTest do
  use ExUnit.Case, async: false

  alias AnkoleWeb.Assets

  setup do
    original_config = Application.get_env(:ankole, Assets)
    original_assets_path = Application.get_env(:ankole, :webapp_assets_path)

    directory =
      Path.join(System.tmp_dir!(), "ankole-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "js"))
    manifest_path = Path.join(directory, "manifest.json")
    File.write!(manifest_path, Ankole.JSON.encode!(manifest()))
    File.write!(Path.join(directory, "js/vendor-react.js"), "export default {}\n")
    Application.put_env(:ankole, Assets, manifest_path: manifest_path)
    Application.put_env(:ankole, :webapp_assets_path, directory)

    on_exit(fn ->
      if original_config,
        do: Application.put_env(:ankole, Assets, original_config),
        else: Application.delete_env(:ankole, Assets)

      if original_assets_path,
        do: Application.put_env(:ankole, :webapp_assets_path, original_assets_path),
        else: Application.delete_env(:ankole, :webapp_assets_path)

      File.rm_rf!(directory)
    end)

    %{manifest_path: manifest_path}
  end

  test "the initial Page loads its route and nested dependencies from the HTML" do
    html = tags("/pages/a-page", "pod")

    assert preloads(html) |> Enum.sort() ==
             ["/assets/js/helper.js", "/assets/js/page.js", "/assets/js/shared.js"]

    assert html =~ ~s(href="/assets/css/page.css")
    assert html =~ ~s(href="/assets/css/helper.css")
    assert html =~ ~s(src="/assets/js/pod.js")
    refute html =~ "/assets/js/chat.js"
    refute html =~ "/assets/js/applet.js"

    for file <- ["shared", "page", "helper"] do
      assert length(Regex.scan(~r|href="/assets/css/#{file}.css"|, html)) == 1
    end
  end

  test "only the initial Chat route gets Chat hints" do
    for path <- ["/", "/conversations/a-conversation"] do
      html = tags(path, "pod")
      assert preloads(html) == ["/assets/js/shared.js", "/assets/js/chat.js"]
      assert html =~ ~s(href="/assets/css/chat.css")
      refute html =~ "/assets/js/page.js"
    end

    for path <- ["/content/recent", "/unknown", "/pages/a-page/unknown"] do
      html = tags(path, "pod")
      assert preloads(html) == ["/assets/js/shared.js"]
      refute html =~ "/assets/js/page.js"
      refute html =~ "/assets/js/chat.js"
    end
  end

  test "route hints require the entry's declared dynamic import", %{manifest_path: path} do
    manifest = put_in(manifest(), ["entrypoints/pod.tsx", "dynamicImports"], [])
    File.write!(path, Ankole.JSON.encode!(manifest))

    assert preloads(tags("/pages/a-page", "pod")) == ["/assets/js/shared.js"]
    assert preloads(tags("/pages/a-page", "auth")) == ["/assets/js/shared.js"]
  end

  test "development keeps Vite's native entry loading" do
    Application.put_env(:ankole, Assets, dev_server: "http://vite.test/")
    html = tags("/pages/a-page", "pod")

    assert html =~ "http://vite.test/entrypoints/pod.tsx"
    refute html =~ "modulepreload"
  end

  test "production Applet frames emit import maps before vendor styles and module preloads" do
    html = Assets.applet_frame_tags() |> IO.iodata_to_binary()

    assert {importmap, _} = :binary.match(html, ~s(<script type="importmap">))
    assert {preload, _} = :binary.match(html, ~s(<link rel="modulepreload"))
    assert importmap < preload

    assert html =~ ~s("@ankole/uikit":"/assets/js/applet-uikit.js")
    assert html =~ ~s("react/jsx-dev-runtime":"/assets/js/applet-react-jsx-dev-runtime.js")
    assert length(Regex.scan(~r|href="/assets/css/uikit.css"|, html)) == 1

    assert preloads(html) == [
             "/assets/js/applet-react.js",
             "/assets/js/vendor-react.js",
             "/assets/js/applet-react-jsx-runtime.js",
             "/assets/js/applet-react-dom.js",
             "/assets/js/applet-react-dom-client.js",
             "/assets/js/applet-sdk.js",
             "/assets/js/applet-uikit.js",
             "/assets/js/shared.js"
           ]

    conn =
      :get
      |> Plug.Test.conn("/assets/js/vendor-react.js")
      |> AnkoleWeb.Endpoint.call(AnkoleWeb.Endpoint.init([]))

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]
  end

  test "development Applet frames initialize their own React refresh runtime" do
    Application.put_env(:ankole, Assets, dev_server: "http://vite.test/")
    html = Assets.applet_frame_tags() |> IO.iodata_to_binary()

    assert html =~
             ~s("@ankole/applet-sdk":"http://vite.test/entrypoints/applet-vendor/applet-sdk.ts")

    assert html =~ "window.$RefreshReg$ = () => {}"
    assert html =~ "http://vite.test/@react-refresh"
    assert html =~ ~s(src="http://vite.test/@vite/client")
    assert {preamble, _} = :binary.match(html, "window.$RefreshReg$")
    assert {client, _} = :binary.match(html, "src=\"http://vite.test/@vite/client\"")
    assert preamble < client
  end

  test "the shell preloads its active and fallback catalogs" do
    for locale <- ["en-US", "zh-Hans-CN", "ja-JP", "ko-KR"] do
      html = Assets.locale_preload_tags(locale) |> IO.iodata_to_binary()
      assert preloads(html) == ["/assets/js/#{locale}.js", "/assets/js/en-US.js"] |> Enum.uniq()
    end
  end

  test "an unknown locale preloads English" do
    html = Assets.locale_preload_tags("unknown-locale") |> IO.iodata_to_binary()
    assert preloads(html) == ["/assets/js/en-US.js"]
  end

  test "development leaves catalogs to Vite" do
    Application.put_env(:ankole, Assets, dev_server: "http://vite.test/")
    assert Assets.locale_preload_tags("ja-JP") == []
  end

  defp tags(path, entry) do
    Plug.Test.conn(:get, path) |> Assets.entry_tags(entry) |> IO.iodata_to_binary()
  end

  defp preloads(html) do
    ~r|<link rel="modulepreload"[^>]+href="([^"]+)"|
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp manifest do
    entries = %{
      "entrypoints/pod.tsx" => %{
        "file" => "js/pod.js",
        "imports" => ["shared"],
        "css" => ["css/pod.css"],
        "dynamicImports" => ["pod/page-workspace.tsx", "pod/chat-page.tsx"]
      },
      "entrypoints/auth.tsx" => %{"file" => "js/auth.js", "imports" => ["shared"]},
      "shared" => %{"file" => "js/shared.js", "css" => ["css/shared.css"]},
      "pod/page-workspace.tsx" => %{
        "file" => "js/page.js",
        "imports" => ["shared", "helper"],
        "css" => ["css/page.css"],
        "dynamicImports" => ["pod/applet-page.tsx"]
      },
      "helper" => %{
        "file" => "js/helper.js",
        "imports" => ["pod/page-workspace.tsx", "entrypoints/pod.tsx"],
        "css" => ["css/helper.css", "css/page.css"]
      },
      "pod/chat-page.tsx" => %{
        "file" => "js/chat.js",
        "imports" => ["shared"],
        "css" => ["css/chat.css"]
      },
      "pod/applet-page.tsx" => %{"file" => "js/applet.js"},
      "vendor-react" => %{"file" => "js/vendor-react.js"},
      "entrypoints/applet-vendor/react.ts" => %{
        "file" => "js/applet-react.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/react-jsx-runtime.ts" => %{
        "file" => "js/applet-react-jsx-runtime.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/react-jsx-dev-runtime.ts" => %{
        "file" => "js/applet-react-jsx-dev-runtime.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/react-dom.ts" => %{
        "file" => "js/applet-react-dom.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/react-dom-client.ts" => %{
        "file" => "js/applet-react-dom-client.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/applet-sdk.ts" => %{
        "file" => "js/applet-sdk.js",
        "imports" => ["vendor-react"]
      },
      "entrypoints/applet-vendor/uikit.ts" => %{
        "file" => "js/applet-uikit.js",
        "imports" => ["vendor-react", "shared"],
        "css" => ["css/uikit.css"]
      }
    }

    catalogs =
      for locale <- ["en-US", "zh-Hans-CN", "ja-JP", "ko-KR"], into: %{} do
        {"../locales/#{locale}.json", %{"file" => "js/#{locale}.js"}}
      end

    Map.merge(entries, catalogs)
  end
end
