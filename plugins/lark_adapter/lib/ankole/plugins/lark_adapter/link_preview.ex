defmodule Ankole.Plugins.LarkAdapter.LinkPreview do
  @moduledoc """
  Handles Feishu / Lark `url.preview.get` callbacks for Pod Page and Brain links.

  Runs inside the connection's tenant context. Only active connections that
  explicitly enable `linkPreview` answer previews, and only live Pages whose URL
  matches the current Pod's canonical origin produce a preview payload.
  """

  alias Ankole.I18n, as: AnkoleI18n
  alias Ankole.I18n.Config, as: I18nConfig
  alias FeishuOpenAPI.Event

  @provider_locales %{
    "zh_cn" => "zh-Hans-CN",
    "en_us" => "en-US",
    "ja_jp" => "ja-JP"
  }

  @spreadsheet_extensions ~w(.xlsx .xls .csv .tsv)
  @word_extensions ~w(.docx .doc)
  @presentation_extensions ~w(.pptx .ppt)

  @doc """
  Processes one `url.preview.get` callback.

  Returns a bare response map (`%{"inline" => ..., "card" => ...}`) on a live
  Page hit so `FeishuOpenAPI.Event.Dispatcher` forwards the payload into the
  WebSocket `data` envelope, or `:ok` to acknowledge without preview data.
  """
  @spec handle_callback(String.t(), Event.t(), [map()]) :: map() | :ok
  def handle_callback(_event_type, %Event{} = event, consumers) when is_list(consumers) do
    with true <- enabled_for_consumers?(consumers),
         url when is_binary(url) and url != "" <- extract_url(event),
         {:ok, tenant} <- Ankole.Tenants.get(Ankole.Repo.tenant_id!()),
         {:ok, page_id} <- AnkoleWeb.PodURL.page_id_from_url(url, tenant),
         {:ok, preview} <- Ankole.Pod.link_preview(page_id) do
      default_locale =
        case AnkoleI18n.configured_default_locale() do
          {:ok, locale} when is_binary(locale) and locale != "" -> locale
          _ -> I18nConfig.release_default_locale()
        end

      build_response(preview, tenant, default_locale: default_locale)
    else
      _ -> :ok
    end
  end

  @doc """
  Builds the `url.preview.get` response map for a resolved Pod Page preview.
  """
  @spec build_response(map(), map(), keyword()) :: map()
  def build_response(preview, tenant, opts \\ []) when is_map(preview) and is_map(tenant) do
    default_locale =
      case Keyword.get(opts, :default_locale) do
        locale when is_binary(locale) and locale != "" -> locale
        _ -> I18nConfig.release_default_locale()
      end

    url =
      Keyword.get_lazy(opts, :url, fn ->
        AnkoleWeb.PodURL.canonical_page_url(tenant, preview)
      end)

    icon = page_icon(preview)
    title = display_title(preview, default_locale)
    prefixed_title = "#{icon} #{title}"
    summary = summary_text(preview)

    tail = [
      meta_element(preview, tenant, default_locale),
      open_button(url, default_locale)
    ]

    elements = if summary == "", do: tail, else: [summary_element(summary) | tail]

    %{
      "inline" => %{
        "title" => prefixed_title
      },
      "card" => %{
        "type" => "raw",
        "data" => %{
          "schema" => "2.0",
          "config" => %{"update_multi" => true},
          "header" => %{
            "title" => %{
              "tag" => "plain_text",
              "content" => prefixed_title
            }
          },
          "body" => %{
            "direction" => "vertical",
            "padding" => "12px 12px 12px 12px",
            "vertical_spacing" => "8px",
            "elements" => elements
          }
        }
      }
    }
  end

  @doc false
  @spec enabled_for_consumers?([map()]) :: boolean()
  def enabled_for_consumers?(consumers) when is_list(consumers) do
    Enum.any?(consumers, &match?(%{kind: :connector, link_preview: true}, &1))
  end

  defp extract_url(%Event{content: content, raw: raw}) do
    get_in(content || %{}, ["context", "url"]) ||
      get_in(raw || %{}, ["event", "context", "url"])
  end

  defp page_icon(%{emoji_icon: emoji}) when is_binary(emoji) and emoji != "", do: emoji

  defp page_icon(%{type: :file} = preview) do
    ext =
      (get_in(preview, [:file, :path]) || Map.get(preview, :name) || "")
      |> Path.extname()
      |> String.downcase(:ascii)

    cond do
      ext in @spreadsheet_extensions -> "📊"
      ext in @word_extensions -> "📝"
      ext in @presentation_extensions -> "📽️"
      true -> "📎"
    end
  end

  defp page_icon(%{type: :knowledge}), do: "📚"
  defp page_icon(%{type: :base}), do: "🗃️"
  defp page_icon(%{type: :applet}), do: "🧩"
  defp page_icon(_preview), do: "📄"

  defp display_title(preview, default_locale) do
    title = String.trim(Map.get(preview, :title) || "")
    name = String.trim(Map.get(preview, :name) || "")

    cond do
      title != "" -> title
      name != "" -> name
      true -> translate("untitled", %{}, default_locale)
    end
  end

  defp summary_text(%{type: :file} = preview) do
    descriptor = file_descriptor(Map.get(preview, :file))
    excerpt = String.trim(Map.get(preview, :excerpt) || "")

    cond do
      descriptor != "" and excerpt != "" -> descriptor <> " — " <> excerpt
      descriptor != "" -> descriptor
      true -> excerpt
    end
  end

  defp summary_text(preview), do: String.trim(Map.get(preview, :excerpt) || "")

  defp file_descriptor(%{path: path, size: size}) do
    ext =
      (path || "")
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.upcase(:ascii)

    size_label = format_bytes(size)

    [ext, size_label]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp file_descriptor(_), do: ""

  defp format_bytes(size) when is_integer(size) and size >= 0 do
    cond do
      size < 1_024 -> "#{size} B"
      size < 1_048_576 -> "#{Float.round(size / 1_024, 1)} KB"
      size < 1_073_741_824 -> "#{Float.round(size / 1_048_576, 1)} MB"
      true -> "#{Float.round(size / 1_073_741_824, 1)} GB"
    end
  end

  defp format_bytes(_), do: ""

  defp summary_element(summary) do
    %{
      "tag" => "div",
      "text" => %{
        "tag" => "plain_text",
        "content" => summary,
        "text_size" => "normal",
        "text_color" => "default"
      }
    }
  end

  defp meta_element(preview, tenant, default_locale) do
    pod_name =
      case String.trim(Map.get(tenant, :display_name) || "") do
        "" -> to_string(Map.get(tenant, :slug) || "Ankole")
        name -> name
      end

    date = format_date(Map.get(preview, :updated_at))
    type_key = page_kind_key(Map.get(preview, :type))

    text =
      localized_plain_text(default_locale, fn locale ->
        kind = translate(type_key, %{}, locale)

        if date do
          translate("meta_with_date", %{pod: pod_name, kind: kind, date: date}, locale)
        else
          translate("meta_without_date", %{pod: pod_name, kind: kind}, locale)
        end
      end)
      |> Map.merge(%{"text_size" => "notation", "text_color" => "grey"})

    %{"tag" => "div", "text" => text}
  end

  defp open_button(url, default_locale) do
    %{
      "tag" => "button",
      "type" => "default",
      "size" => "small",
      "text" => localized_plain_text(default_locale, &translate("open_page", %{}, &1)),
      "behaviors" => [%{"type" => "open_url", "default_url" => url}]
    }
  end

  defp localized_plain_text(default_locale, render_fn) do
    i18n_content =
      Map.new(@provider_locales, fn {provider_locale, ankole_locale} ->
        {provider_locale, render_fn.(ankole_locale)}
      end)

    %{
      "tag" => "plain_text",
      "content" => render_fn.(default_locale),
      "i18n_content" => i18n_content
    }
  end

  defp page_kind_key(:knowledge), do: "kind_knowledge"
  defp page_kind_key(:base), do: "kind_base"
  defp page_kind_key(:file), do: "kind_file"
  defp page_kind_key(:applet), do: "kind_applet"
  defp page_kind_key(_), do: "kind_doc"

  defp format_date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
  defp format_date(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_date() |> Date.to_iso8601()
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: nil

  defp translate(key, bindings, locale) when is_binary(locale),
    do: AnkoleI18n.t("plugins.lark.link_preview.#{key}", bindings, locale: locale)
end
