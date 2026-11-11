defmodule Ankole.Pod.Pages.Search.Targets do
  @moduledoc """
  Deep-link `primary_target` resolution for winning `Ankole.Pod.Pages.Search`
  results.

  Document section targets use `Ankole.Kernel.page_sections/1` so heading labels
  and byte offsets come from the canonical page XML AST rather than regex tag
  stripping. File targets derive coordinates from `FileCache` metadata, and
  every returned target satisfies all required fields for its `kind` or returns
  `nil`.
  """

  require Ash.Query

  alias Ankole.Pod.{
    BaseField,
    BaseTable,
    BaseView,
    FileCache,
    Page,
    PageContent,
    SearchProjection
  }

  @doc "Resolves `%{page_id => primary_target | nil}` for the returned pages."
  @spec resolve_targets([Page.t()], map(), map(), [String.t()], boolean()) :: %{
          optional(String.t()) => map() | nil
        }
  def resolve_targets(_pages, _rows_by_id, _match_fields_by_id, _lower_terms, true), do: %{}

  def resolve_targets(pages, rows_by_id, match_fields_by_id, lower_terms, false) do
    base_targets =
      pages
      |> Enum.filter(&(&1.type == :base))
      |> Enum.map(& &1.id)
      |> load_base_targets(lower_terms)

    file_caches =
      pages
      |> Enum.filter(&(&1.type == :file and :body in Map.get(match_fields_by_id, &1.id, [])))
      |> Enum.map(& &1.id)
      |> load_file_caches()

    doc_xml_by_id =
      pages
      |> Enum.filter(
        &(&1.type in [:doc, :knowledge] and :body in Map.get(match_fields_by_id, &1.id, []))
      )
      |> Enum.map(& &1.id)
      |> load_doc_xml()

    Map.new(pages, fn page ->
      cand = Map.get(rows_by_id, page.id, %{body_text: ""})
      match_fields = Map.get(match_fields_by_id, page.id, [])

      target =
        resolve_page_target(
          page,
          cand,
          match_fields,
          lower_terms,
          base_targets,
          file_caches,
          doc_xml_by_id
        )

      {page.id, target}
    end)
  end

  defp resolve_page_target(
         %Page{type: :base, id: id},
         _cand,
         _match_fields,
         _lower_terms,
         base_targets,
         _file_caches,
         _doc_xml_by_id
       ) do
    Map.get(base_targets, id)
  end

  defp resolve_page_target(
         %Page{type: :file, id: id},
         cand,
         match_fields,
         lower_terms,
         _base_targets,
         file_caches,
         _doc_xml_by_id
       ) do
    with true <- :body in match_fields,
         %FileCache{extract_status: :ok} = cache <- Map.get(file_caches, id),
         body when is_binary(body) and body != "" <- cand.body_text,
         {match_byte, match_line} <- first_match_position(body, lower_terms) do
      file_target_from_cache(cache, body, match_byte, match_line)
    else
      _ -> nil
    end
  end

  defp resolve_page_target(
         %Page{type: type, id: id},
         _cand,
         match_fields,
         lower_terms,
         _base_targets,
         _file_caches,
         doc_xml_by_id
       )
       when type in [:doc, :knowledge] do
    if :body in match_fields do
      case Map.get(doc_xml_by_id, id) do
        xml when is_binary(xml) and xml != "" -> doc_section_target(xml, lower_terms)
        _ -> nil
      end
    else
      nil
    end
  end

  defp resolve_page_target(_page, _cand, _fields, _terms, _bases, _files, _docs), do: nil

  defp load_base_targets([], _lower_terms), do: %{}

  defp load_base_targets(base_ids, lower_terms) do
    tables =
      BaseTable
      |> Ash.Query.filter(page_id in ^base_ids and is_nil(deleting_at))
      |> Ash.Query.sort(position: :asc, id: :asc)
      |> Ash.Query.select([:id, :page_id, :name])
      |> Ankole.Ash.read!()

    table_ids = Enum.map(tables, & &1.id)
    table_by_id = Map.new(tables, &{&1.id, &1})

    views =
      if table_ids == [] do
        []
      else
        BaseView
        |> Ash.Query.filter(table_id in ^table_ids)
        |> Ash.Query.sort(position: :asc, id: :asc)
        |> Ash.Query.select([:id, :table_id, :name])
        |> Ankole.Ash.read!()
      end

    fields =
      if table_ids == [] do
        []
      else
        BaseField
        |> Ash.Query.filter(table_id in ^table_ids)
        |> Ash.Query.sort(position: :asc, id: :asc)
        |> Ash.Query.select([:id, :table_id, :name])
        |> Ankole.Ash.read!()
      end

    tables_by_page = Enum.group_by(tables, & &1.page_id)
    views_by_page = Enum.group_by(views, &Map.fetch!(table_by_id, &1.table_id).page_id)
    fields_by_page = Enum.group_by(fields, &Map.fetch!(table_by_id, &1.table_id).page_id)

    Map.new(base_ids, fn page_id ->
      page_tables = Map.get(tables_by_page, page_id, [])
      page_views = Map.get(views_by_page, page_id, [])
      page_fields = Map.get(fields_by_page, page_id, [])

      target =
        cond do
          matched_view = Enum.find(page_views, &name_matches?(&1.name, lower_terms)) ->
            %{
              kind: :base_table,
              table_id: matched_view.table_id,
              view_id: matched_view.id,
              label: matched_view.name
            }

          matched_table = Enum.find(page_tables, &name_matches?(&1.name, lower_terms)) ->
            %{
              kind: :base_table,
              table_id: matched_table.id,
              label: matched_table.name
            }

          matched_field = Enum.find(page_fields, &name_matches?(&1.name, lower_terms)) ->
            %{
              kind: :base_table,
              table_id: matched_field.table_id,
              label: matched_field.name
            }

          true ->
            nil
        end

      {page_id, target}
    end)
  end

  defp name_matches?(name, lower_terms) when is_binary(name) do
    down = name |> SearchProjection.sanitize() |> String.downcase()
    down != "" and Enum.any?(lower_terms, &String.contains?(down, &1))
  end

  defp name_matches?(_, _), do: false

  defp load_file_caches([]), do: %{}

  defp load_file_caches(file_ids) do
    FileCache
    |> Ash.Query.filter(page_id in ^file_ids)
    |> Ash.Query.select([:page_id, :subtype, :format, :extract_status, :metadata])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.page_id, &1})
  end

  defp load_doc_xml([]), do: %{}

  defp load_doc_xml(doc_ids) do
    PageContent
    |> Ash.Query.filter(page_id in ^doc_ids)
    |> Ash.Query.select([:page_id, :content])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.page_id, &1.content})
  end

  defp first_match_position(body, lower_terms) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({0, nil}, fn {line, line_no}, {byte_acc, _found} ->
      case match_col_byte(line, String.downcase(line), lower_terms) do
        nil -> {:cont, {byte_acc + byte_size(line) + 1, nil}}
        col_byte -> {:halt, {byte_acc, {byte_acc + col_byte, line_no}}}
      end
    end)
    |> elem(1)
  end

  defp match_col_byte(line, down_line, lower_terms) do
    case Enum.find_value(lower_terms, fn term ->
           case :binary.match(down_line, term) do
             {pos, _len} -> pos
             :nomatch -> nil
           end
         end) do
      nil ->
        nil

      pos when byte_size(down_line) == byte_size(line) ->
        pos

      pos ->
        char_idx = down_line |> binary_part(0, pos) |> String.length()
        line |> String.slice(0, char_idx) |> byte_size()
    end
  end

  defp file_target_from_cache(%FileCache{} = cache, body, match_byte, match_line) do
    meta = cache.metadata || %{}

    cond do
      target = sheet_target_from_metadata(meta, body, match_byte, match_line) ->
        target

      cache.format in ["pdf", "pptx"] ->
        page_number_target(meta, match_byte)

      cache.format in ["csv", "tsv"] ->
        row = max(match_line - 1, 1)
        %{kind: :csv_rows, start_row: row, end_row: row}

      cache.format == "md" ->
        md_target(body, match_line)

      cache.subtype == :text ->
        %{kind: :lines, start_line: match_line, end_line: match_line}

      true ->
        nil
    end
  end

  defp sheet_target_from_metadata(meta, body, match_byte, match_line) when is_map(meta) do
    case Map.get(meta, "sheet_spans") do
      spans when is_list(spans) and spans != [] ->
        matched_name =
          Enum.find_value(spans, fn
            %{"sheet_name" => name, "start_byte" => s, "end_byte" => e}
            when is_binary(name) and is_integer(s) and is_integer(e) ->
              if match_byte >= s and match_byte < e, do: sanitize_non_empty(name), else: nil

            _ ->
              nil
          end) ||
            spans
            |> Enum.filter(fn
              %{"sheet_name" => name, "start_byte" => s}
              when is_binary(name) and is_integer(s) ->
                s <= match_byte

              _ ->
                false
            end)
            |> List.last()
            |> case do
              %{"sheet_name" => name} -> sanitize_non_empty(name)
              _ -> nil
            end

        if matched_name, do: %{kind: :spreadsheet_cell, sheet_name: matched_name}, else: nil

      _ ->
        sheet_names = extract_sheet_names(Map.get(meta, "sheets"))

        if sheet_names == [] do
          nil
        else
          # The kernel opens each sheet's rows with a `[Sheet: name]` line.
          opened =
            for "[Sheet: " <> rest <- body |> String.split("\n") |> Enum.take(match_line),
                do: String.replace_suffix(rest, "]", "")

          {active_sheet, _remaining} =
            Enum.reduce(opened, {hd(sheet_names), sheet_names}, fn name, {current, pending} ->
              case pending do
                [^name | rest] -> {name, rest}
                _ -> {current, pending}
              end
            end)

          %{kind: :spreadsheet_cell, sheet_name: active_sheet}
        end
    end
  end

  defp extract_sheet_names(sheets) when is_list(sheets) do
    sheets
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> sanitize_non_empty(name)
      name when is_binary(name) -> sanitize_non_empty(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_sheet_names(_), do: []

  defp sanitize_non_empty(value) when is_binary(value) do
    case value |> SearchProjection.sanitize() |> String.trim() do
      "" -> nil
      clean -> clean
    end
  end

  defp page_number_target(meta, match_byte) do
    pages = Map.get(meta, "pages", [])

    matched_page =
      Enum.find_value(pages, fn
        %{"page" => page_no, "start_byte" => s, "end_byte" => e}
        when is_integer(page_no) and page_no >= 1 and is_integer(s) and is_integer(e) ->
          if match_byte >= s and match_byte < e, do: page_no, else: nil

        _ ->
          nil
      end) ||
        case List.last(pages) do
          %{"page" => page_no} when is_integer(page_no) and page_no >= 1 -> page_no
          _ -> nil
        end

    if matched_page, do: %{kind: :page_number, page: matched_page}, else: nil
  end

  defp md_target(body, match_line) do
    heading =
      body
      |> String.split("\n")
      |> Enum.take(match_line)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Regex.run(~r/^(\#{1,6})\s+(.+?)\s*$/u, line) do
          [_, hashes, text] -> {String.length(hashes), String.trim(text)}
          _ -> nil
        end
      end)

    case heading do
      {level, text} when text != "" and level in 1..6 ->
        %{kind: :md_section, heading: text, level: level, start_line: match_line}

      _ ->
        %{kind: :lines, start_line: match_line, end_line: match_line}
    end
  end

  defp doc_section_target(xml, lower_terms) do
    with {:ok, %{plain_text: plain_text, sections: [_ | _] = sections}} <-
           Ankole.Kernel.page_sections(xml),
         {match_byte, _match_line} <- first_match_position(plain_text, lower_terms),
         %{heading: heading, level: level} when heading != "" and level in 1..6 <-
           sections
           |> Enum.take_while(&(&1.start_byte <= match_byte))
           |> List.last() do
      %{kind: :doc_section, heading: heading, level: level}
    else
      _ -> nil
    end
  end
end
