defmodule Ankole.Pod.SearchProjection do
  @moduledoc """
  Maintains the synchronous `page_search_documents` projection for Pod pages.

  Every write normalizes text to NFKC, strips NUL and the ASCII record/unit
  separators (`0x1E` / `0x1F`) reserved as `pg_search` snippet delimiters, and
  inserts a space after every 256 characters of an unbroken run in a
  dictionary-segmented script (Han, kana, Thai, Lao, Khmer, Myanmar). The ICU
  tokenizer segments such a run in time quadratic to its length without
  honoring query cancellation, so the split keeps indexing cost linear.
  """

  require Ash.Query

  alias Ankole.Pod.{BaseField, BaseTable, BaseView, Page, PageContent, PageSearchDocument, Pages}
  alias Ankole.Repo

  @stripped_codepoints [<<0>>, <<0x1E>>, <<0x1F>>]
  # `sc=` matches the Script property, not Script_Extensions, so punctuation
  # such as 。 still ends a run as it does for ICU. The lookbehind anchors each
  # attempt at the start of a run, so scanning stays linear.
  @long_dictionary_run ~r/(?<![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\x{30FC}\p{sc=Thai}\p{sc=Lao}\p{sc=Khmer}\p{sc=Myanmar}])[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\x{30FC}\p{sc=Thai}\p{sc=Lao}\p{sc=Khmer}\p{sc=Myanmar}]{257,}/u
  @dictionary_run_chunk ~r/.{256}(?=.)/su

  @doc "Normalizes text to NFKC, strips snippet sentinel bytes, and splits long dictionary-script runs."
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(text) when is_binary(text) do
    normalized =
      case :unicode.characters_to_nfkc_binary(text) do
        bin when is_binary(bin) -> bin
        _ -> text
      end

    normalized
    |> String.replace(@stripped_codepoints, "")
    |> then(
      &Regex.replace(@long_dictionary_run, &1, fn run ->
        Regex.replace(@dictionary_run_chunk, run, "\\0 ")
      end)
    )
  end

  @doc "Returns the display title indexed for `page`."
  @spec display_title(Page.t() | map()) :: String.t()
  def display_title(page) do
    trimmed = String.trim(Map.get(page, :title) || "")
    raw = if trimmed == "", do: Map.get(page, :name) || "", else: trimmed
    sanitize(raw)
  end

  @doc """
  Upserts the `PageSearchDocument` row for `page` inside the caller's transaction.

  Options:
  - `:body_text` — explicit body text to store; when omitted, keeps the existing
    `body_text` (or reads `PageContent.plain_text` when creating a missing row
    for a `:doc` or `:knowledge` page).
  - `:meta_text` — explicit metadata text to store; when omitted, derives it
    from `page` and its live schema children.
  """
  @spec upsert_in_tx(Page.t(), keyword()) :: :ok | {:error, term()}
  def upsert_in_tx(%Page{} = page, opts \\ []) do
    Repo.require_transaction!({__MODULE__, :upsert_in_tx})

    existing =
      PageSearchDocument
      |> Ash.Query.filter(page_id == ^page.id)
      |> Ankole.Ash.read_one!()

    title = display_title(page)

    meta_text =
      if Keyword.has_key?(opts, :meta_text) do
        sanitize(Keyword.get(opts, :meta_text) || "")
      else
        derive_meta_text_in_tx(page)
      end

    body_text =
      cond do
        Keyword.has_key?(opts, :body_text) ->
          sanitize(Keyword.get(opts, :body_text) || "")

        existing != nil ->
          existing.body_text

        page.type in [:doc, :knowledge] ->
          content =
            PageContent
            |> Ash.Query.filter(page_id == ^page.id)
            |> Ash.Query.select([:plain_text])
            |> Ankole.Ash.read_one!()

          sanitize(content && content.plain_text)

        true ->
          ""
      end

    if existing != nil and existing.title == title and existing.meta_text == meta_text and
         existing.body_text == body_text do
      :ok
    else
      now = page.updated_at || DateTime.utc_now(:microsecond)

      case Ankole.Ash.create(PageSearchDocument, :put, %{
             page_id: page.id,
             title: title,
             meta_text: meta_text,
             body_text: body_text,
             updated_at: now
           }) do
        {:ok, _row} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc "Recomputes `meta_text` for a Base page from its live tables, views, and fields."
  @spec sync_base_in_tx(String.t()) :: :ok | {:error, term()}
  def sync_base_in_tx(page_id) when is_binary(page_id) do
    Repo.require_transaction!({__MODULE__, :sync_base_in_tx})

    case Pages.fetch(page_id) do
      {:ok, %Page{type: :base} = page} -> upsert_in_tx(page)
      {:ok, _other} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc "Derives `meta_text` for `page` inside the caller's transaction."
  @spec derive_meta_text_in_tx(Page.t()) :: String.t()
  def derive_meta_text_in_tx(%Page{type: :knowledge, metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.drop(["subtype", "extract_facts"])
    |> Enum.sort_by(fn {key, _val} -> to_string(key) end)
    |> Enum.flat_map(fn {_key, value} -> flatten_metadata_value(value) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> sanitize()
  end

  def derive_meta_text_in_tx(%Page{type: :base, id: page_id}) do
    tables =
      BaseTable
      |> Ash.Query.filter(page_id == ^page_id and is_nil(deleting_at))
      |> Ash.Query.sort(position: :asc, id: :asc)
      |> Ash.Query.select([:id, :name])
      |> Ankole.Ash.read!()

    table_ids = Enum.map(tables, & &1.id)

    views =
      if table_ids == [] do
        []
      else
        BaseView
        |> Ash.Query.filter(table_id in ^table_ids)
        |> Ash.Query.sort(position: :asc, id: :asc)
        |> Ash.Query.select([:name])
        |> Ankole.Ash.read!()
      end

    fields =
      if table_ids == [] do
        []
      else
        BaseField
        |> Ash.Query.filter(table_id in ^table_ids)
        |> Ash.Query.sort(position: :asc, id: :asc)
        |> Ash.Query.select([:name])
        |> Ankole.Ash.read!()
      end

    (Enum.map(tables, & &1.name) ++ Enum.map(views, & &1.name) ++ Enum.map(fields, & &1.name))
    |> Enum.map(&String.trim(&1 || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> sanitize()
  end

  def derive_meta_text_in_tx(%Page{type: :file, name: name, title: title}) do
    trimmed_title = String.trim(title || "")
    trimmed_name = String.trim(name || "")

    if trimmed_name != "" and trimmed_name != trimmed_title do
      sanitize(trimmed_name)
    else
      ""
    end
  end

  def derive_meta_text_in_tx(_page), do: ""

  defp flatten_metadata_value(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: [], else: [trimmed]
  end

  defp flatten_metadata_value(val) when is_number(val), do: [to_string(val)]

  defp flatten_metadata_value(val) when is_list(val) do
    joined =
      val
      |> Enum.flat_map(fn
        item when is_binary(item) -> [String.trim(item)]
        item when is_number(item) -> [to_string(item)]
        _ -> []
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    if joined == "", do: [], else: [joined]
  end

  defp flatten_metadata_value(_other), do: []
end
