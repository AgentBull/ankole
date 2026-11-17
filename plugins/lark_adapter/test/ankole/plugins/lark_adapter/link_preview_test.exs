defmodule Ankole.Plugins.LarkAdapter.LinkPreviewTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.LinkPreview
  alias FeishuOpenAPI.Event.Dispatcher
  alias FeishuOpenAPI.WS.Protocol

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:localize)

    unless Process.whereis(Ankole.I18n.Catalog) do
      {:ok, _catalog} = Ankole.I18n.Catalog.start_link([])
    end

    :ok
  end

  test "build_response renders plain_text summary without markdown re-interpretation and encodes into WS data" do
    raw_summary = "Keep *asterisks*, `backticks`, and [links](https://example.com) literal."

    preview = %{
      id: "019a8c3e-1234-7000-8000-000000000001",
      title: "Q4 Architecture Review",
      name: "q4-review",
      type: :doc,
      domain: :pages,
      emoji_icon: "📐",
      excerpt: raw_summary,
      file: nil,
      updated_at: ~U[2026-11-16 09:30:00Z]
    }

    tenant = %{display_name: "Acme Workspace", slug: "acme"}
    canonical_url = "https://acme.ankole.example/pages/q4-architecture-review-06d8"

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("url.preview.get", fn _type, _event ->
        LinkPreview.build_response(preview, tenant,
          url: canonical_url,
          default_locale: "zh-Hans-CN"
        )
      end)

    envelope = %{
      "schema" => "2.0",
      "header" => %{"event_type" => "url.preview.get"},
      "event" => %{"context" => %{"url" => canonical_url}}
    }

    assert {:ok, handler_payload} = Dispatcher.dispatch(dispatcher, {:trusted_decoded, envelope})
    assert {:ok, ws_json} = Protocol.encode_ws_response({:ok, handler_payload})
    assert %{"code" => 200, "data" => encoded_data} = Torque.decode!(ws_json)

    decoded = encoded_data |> Base.decode64!() |> Torque.decode!()
    assert decoded["inline"] == %{"title" => "📐 Q4 Architecture Review"}
    assert get_in(decoded, ["card", "type"]) == "raw"

    card = get_in(decoded, ["card", "data"])
    assert card["schema"] == "2.0"
    assert get_in(card, ["header", "title", "content"]) == "📐 Q4 Architecture Review"

    [summary_el, meta_el, button_el] = get_in(card, ["body", "elements"])

    assert summary_el == %{
             "tag" => "div",
             "text" => %{
               "tag" => "plain_text",
               "content" => raw_summary,
               "text_size" => "normal",
               "text_color" => "default"
             }
           }

    assert get_in(meta_el, ["text", "tag"]) == "plain_text"
    assert get_in(meta_el, ["text", "content"]) == "Acme Workspace · 文档 · 更新于 2026-11-16"

    assert get_in(meta_el, ["text", "i18n_content", "en_us"]) ==
             "Acme Workspace · Document · Updated 2026-11-16"

    assert get_in(button_el, ["text", "content"]) == "打开页面"
    assert get_in(button_el, ["text", "i18n_content", "en_us"]) == "Open page"

    assert get_in(button_el, ["behaviors"]) == [
             %{"type" => "open_url", "default_url" => canonical_url}
           ]
  end

  test "build_response omits empty summary elements for applet and blank pages and formats file descriptors" do
    tenant = %{display_name: "Acme", slug: "acme"}

    applet_resp =
      LinkPreview.build_response(
        %{
          id: "019a8c3e-1234-7000-8000-000000000002",
          title: "Ops Console",
          name: "ops",
          type: :applet,
          domain: :pages,
          emoji_icon: nil,
          excerpt: "",
          file: nil,
          updated_at: ~U[2026-11-16 00:00:00Z]
        },
        tenant,
        url: "https://acme.ankole.example/pages/ops-console-06d8",
        default_locale: "en-US"
      )

    assert applet_resp["inline"] == %{"title" => "🧩 Ops Console"}
    assert [meta_el, button_el] = get_in(applet_resp, ["card", "data", "body", "elements"])
    assert get_in(meta_el, ["text", "content"]) == "Acme · App · Updated 2026-11-16"
    assert get_in(button_el, ["text", "content"]) == "Open page"

    # Falls back to release default locale ("en-US") without raising when :default_locale is omitted/nil.
    fallback_resp =
      LinkPreview.build_response(
        %{
          id: "019a8c3e-1234-7000-8000-000000000002",
          title: "",
          name: "",
          type: :doc,
          domain: :pages,
          emoji_icon: nil,
          excerpt: "",
          file: nil,
          updated_at: nil
        },
        tenant,
        url: "https://acme.ankole.example/pages/06d8"
      )

    assert fallback_resp["inline"] == %{"title" => "📄 Untitled page"}

    file_resp =
      LinkPreview.build_response(
        %{
          id: "019a8c3e-1234-7000-8000-000000000003",
          title: "",
          name: "budget.xlsx",
          type: :file,
          domain: :brain,
          emoji_icon: nil,
          excerpt: "Sheet1 Revenue Q1 Q2",
          file: %{path: "budget.xlsx", size: 204_800, content_type: "application/octet-stream"},
          updated_at: ~U[2026-11-16 00:00:00Z]
        },
        tenant,
        url: "https://acme.ankole.example/meta/brain/019a8c3e-1234-7000-8000-000000000003",
        default_locale: "en-US"
      )

    assert file_resp["inline"] == %{"title" => "📊 budget.xlsx"}
    [file_summary, _meta, file_button] = get_in(file_resp, ["card", "data", "body", "elements"])
    assert get_in(file_summary, ["text", "content"]) == "XLSX · 200.0 KB — Sheet1 Revenue Q1 Q2"

    assert get_in(file_button, ["behaviors"]) == [
             %{
               "type" => "open_url",
               "default_url" =>
                 "https://acme.ankole.example/meta/brain/019a8c3e-1234-7000-8000-000000000003"
             }
           ]
  end

  test "enabled_for_consumers? checks explicit link_preview flags" do
    refute LinkPreview.enabled_for_consumers?([])
    refute LinkPreview.enabled_for_consumers?([%{kind: :chat, config: %{}}])
    refute LinkPreview.enabled_for_consumers?([%{kind: :connector, link_preview: false}])
    assert LinkPreview.enabled_for_consumers?([%{kind: :connector, link_preview: true}])
  end
end
