defmodule AnkoleWeb.AssetsTest do
  use ExUnit.Case, async: false

  alias AnkoleWeb.Assets

  setup do
    original_config = Application.get_env(:ankole, Assets)

    directory =
      Path.join(System.tmp_dir!(), "ankole-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    manifest_path = Path.join(directory, "manifest.json")
    File.write!(manifest_path, Ankole.JSON.encode!(manifest()))
    Application.put_env(:ankole, Assets, manifest_path: manifest_path)

    on_exit(fn ->
      if original_config,
        do: Application.put_env(:ankole, Assets, original_config),
        else: Application.delete_env(:ankole, Assets)

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

  test "Pod and SaaS Pod preload only their scoped active and fallback catalogs" do
    for entry <- ["pod", "saas-pod"], locale <- ["en-US", "zh-Hans-CN", "ja-JP", "ko-KR"] do
      html = Assets.locale_preload_tags(locale, entry) |> IO.iodata_to_binary()

      assert preloads(html) ==
               ["/assets/js/#{locale}-pod.js", "/assets/js/en-US-pod.js"] |> Enum.uniq()

      refute html =~ "-full.js"
    end
  end

  test "other entries keep full catalogs and an unknown locale still preloads English" do
    for entry <- ["auth", "setup", "console", "saas-account", nil] do
      html = Assets.locale_preload_tags("zh-Hans-CN", entry) |> IO.iodata_to_binary()
      assert preloads(html) == ["/assets/js/zh-Hans-CN-full.js", "/assets/js/en-US-full.js"]
      refute html =~ "-pod.js"
    end

    html = Assets.locale_preload_tags("unknown-locale", "pod") |> IO.iodata_to_binary()
    assert preloads(html) == ["/assets/js/en-US-pod.js"]
  end

  test "development leaves scoped catalogs to Vite" do
    Application.put_env(:ankole, Assets, dev_server: "http://vite.test/")
    assert Assets.locale_preload_tags("ja-JP", "pod") == []
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
      "pod/applet-page.tsx" => %{"file" => "js/applet.js"}
    }

    catalogs =
      for locale <- ["en-US", "zh-Hans-CN", "ja-JP", "ko-KR"],
          {query, name} <- [{"", "full"}, {"?pod", "pod"}],
          into: %{} do
        {"../locales/#{locale}.json#{query}", %{"file" => "js/#{locale}-#{name}.js"}}
      end

    Map.merge(entries, catalogs)
  end
end
