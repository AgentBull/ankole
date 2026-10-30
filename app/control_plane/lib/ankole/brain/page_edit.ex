defmodule Ankole.Brain.PageEdit do
  @moduledoc """
  Model-facing page creation and surgical Markdoc editing (`put_page` and `edit_page`).

  `put_page` creates a new knowledge page or replaces an existing page under a
  compare-and-swap revision check when the caller can see and write every
  existing segment. `edit_page` applies ordered `old_text -> new_text`
  replacements strictly inside the Markdoc segments the caller may both read
  and write, preserving hidden `{% audience %}` blocks of other audiences and
  generated calibration scorecards.
  """

  alias Ankole.ActorRef
  alias Ankole.Brain.Access
  alias Ankole.Brain.Calibration
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Links
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Tools.Context
  alias Ankole.Repo
  alias Ankole.Text

  @max_edits 50
  @max_body_bytes 200_000
  @max_diff_bytes 8_192
  @diff_context_lines 2
  @calibration_probe_scope "principal:calibration_probe"

  @doc """
  Creates a page (when `expected_revision` is absent) or replaces a page's
  content under `expected_revision` compare-and-swap.
  """
  @spec put_page(map(), Context.t()) :: {:ok, map()} | {:error, term()}
  def put_page(params, %Context{} = context) when is_map(params) do
    case optional_trimmed(params, "expected_revision") do
      {:ok, nil} -> create_page(params, context)
      {:ok, expected_revision} -> replace_page(params, expected_revision, context)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Applies 1..#{@max_edits} sequential exact-match replacements to the
  caller-editable segments of one page under `expected_revision` CAS.
  """
  @spec edit_page(map(), Context.t()) :: {:ok, map()} | {:error, term()}
  def edit_page(params, %Context{} = context) when is_map(params) do
    with {:ok, slug} <- required_trimmed(params, "slug"),
         {:ok, expected_revision} <- required_trimmed(params, "expected_revision"),
         {:ok, edits} <- validate_edits(Map.get(params, "edits")),
         :ok <- Context.fence(context),
         {:ok, access} <- Access.for_readers(context.querier_uid, context.disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(context.querier_uid) do
      Repo.transact_top_level(fn ->
        edit_page_in_tx(slug, expected_revision, edits, access, visibility, context)
      end)
    end
  end

  defp create_page(params, context) do
    with {:ok, slug} <- required_trimmed(params, "slug"),
         {:ok, type} <- required_trimmed(params, "type"),
         {:ok, title} <- required_trimmed(params, "title"),
         {:ok, raw_content} <- required_binary(params, "content"),
         content = normalize_newlines(raw_content),
         :ok <- guard_body_size(content),
         :ok <- reject_calibration_markers(content),
         {:ok, subtype} <- optional_trimmed(params, "subtype"),
         {:ok, tags} <- optional_string_list(params, "tags", []),
         {:ok, aliases} <- optional_string_list(params, "aliases", []),
         {:ok, scope} <- Context.write_scope(params["scope"], context),
         {:ok, body} <- Markdoc.apply_default_scope(content, scope),
         :ok <- guard_body_size(body),
         :ok <- validate_caller_scopes(body, context.querier_uid),
         :ok <- Context.fence(context),
         {:ok, object} <-
           Repo.transact_top_level(fn ->
             create_page_in_tx(
               %{slug: slug, type: type, subtype: subtype, title: title, body: body, tags: tags},
               aliases,
               context.querier_uid
             )
           end) do
      {:ok,
       %{
         "status" => "created",
         "slug" => object.slug,
         "revision" => object.content_hash,
         "type" => object.type,
         "title" => object.title
       }}
    end
  end

  defp create_page_in_tx(attrs, aliases, writer_uid) do
    with {:ok, object} <- Objects.create_object_in_tx(attrs, writer_uid),
         :ok <- add_aliases(object.slug, aliases),
         {:ok, _reconciled} <- Links.reconcile_object_links_in_tx(object.slug) do
      {:ok, object}
    end
  end

  defp replace_page(params, expected_revision, context) do
    with {:ok, slug} <- required_trimmed(params, "slug"),
         {:ok, raw_content} <- required_binary(params, "content"),
         content = normalize_newlines(raw_content),
         :ok <- guard_body_size(content),
         :ok <- guard_non_empty(content, params["allow_empty"] == true),
         {:ok, title} <- optional_trimmed(params, "title"),
         {:ok, subtype_opt} <- fetch_optional_trimmed(params, "subtype"),
         {:ok, tags_opt} <- fetch_optional_string_list(params, "tags"),
         {:ok, aliases} <- optional_string_list(params, "aliases", []),
         {:ok, explicit_scope} <- optional_explicit_scope(params["scope"], context),
         :ok <- Context.fence(context),
         {:ok, access} <- Access.for_readers(context.querier_uid, context.disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(context.querier_uid),
         {:ok, object} <-
           Repo.transact_top_level(fn ->
             replace_page_in_tx(
               slug,
               expected_revision,
               content,
               %{
                 title: title,
                 subtype: subtype_opt,
                 tags: tags_opt,
                 aliases: aliases,
                 explicit_scope: explicit_scope
               },
               access,
               visibility,
               context
             )
           end) do
      {:ok,
       %{
         "status" => "updated",
         "slug" => object.slug,
         "revision" => object.content_hash,
         "type" => object.type,
         "title" => object.title
       }}
    end
  end

  defp replace_page_in_tx(slug, expected_revision, content, opts, access, visibility, context) do
    with {:ok, locked} <- resolve_and_lock_live(slug, visibility),
         :ok <- Objects.guard_editable(locked),
         :ok <- verify_revision(locked, expected_revision),
         existing_body = normalize_newlines(locked.body),
         :ok <- Access.guard_body_replacement(existing_body, access, context.disclosure),
         {:ok, body_with_scope} <-
           resolve_replace_body(existing_body, content, opts.explicit_scope, context),
         :ok <-
           validate_caller_scopes(
             Calibration.strip_calibration_section(body_with_scope),
             context.querier_uid
           ),
         {:ok, final_body} <- preserve_existing_calibration(existing_body, body_with_scope),
         :ok <- guard_body_size(final_body),
         update_attrs = build_replace_attrs(locked, expected_revision, final_body, opts),
         {:ok, updated} <-
           Objects.update_object_in_tx(locked.slug, update_attrs, context.querier_uid),
         :ok <- add_aliases(updated.slug, opts.aliases),
         {:ok, _reconciled} <- Links.reconcile_object_links_in_tx(updated.slug) do
      {:ok, updated}
    end
  end

  defp edit_page_in_tx(slug, expected_revision, edits, access, visibility, context) do
    with {:ok, locked} <- resolve_and_lock_live(slug, visibility),
         :ok <- Objects.guard_editable(locked),
         :ok <- verify_revision(locked, expected_revision),
         existing_body = normalize_newlines(locked.body),
         {:ok, spans} <- build_spans(existing_body, access, context),
         before_visible = visible_text(spans),
         {:ok, updated_spans} <- apply_edits(spans, edits),
         new_body = render_spans(updated_spans),
         :ok <-
           validate_edited_document(updated_spans, new_body, existing_body, context.querier_uid),
         author =
           ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: context.querier_uid}),
         {:ok, updated} <-
           Objects.update_object_in_tx(
             locked.slug,
             %{body: new_body, expected_content_hash: expected_revision},
             :system,
             author: author
           ),
         {:ok, _reconciled} <- Links.reconcile_object_links_in_tx(updated.slug) do
      after_visible = visible_text(updated_spans)

      {:ok,
       %{
         "status" => "updated",
         "slug" => updated.slug,
         "revision" => updated.content_hash,
         "diff" => compact_diff(before_visible, after_visible)
       }}
    end
  end

  defp resolve_and_lock_live(slug, visibility) do
    with {:ok, resolved} <- Objects.resolve_slug(slug, lazy_skill_visibility: visibility),
         {:ok, locked} <- Objects.lock_object_in_tx(resolved.slug) do
      if is_nil(locked.deleted_at), do: {:ok, locked}, else: {:error, :not_found}
    end
  end

  defp verify_revision(%Object{content_hash: current}, expected) do
    if current == expected do
      :ok
    else
      {:error,
       {:revision_conflict,
        %{
          current_revision: current,
          hint:
            "Re-read the page with get_page(include_content: true) and retry with current_revision."
        }}}
    end
  end

  defp build_spans(body, access, context) do
    with {:ok, raw_segments} <- Markdoc.raw_segments(body) do
      spans =
        raw_segments
        |> Enum.map(&classify_segment(&1, access, context))
        |> group_writable_units()
        |> expand_unit_calibration_spans()

      {:ok, spans}
    end
  end

  defp classify_segment(segment, access, context) do
    rendered = Markdoc.render_segment(segment)

    cond do
      not segment_visible?(segment.scope, access, context.disclosure) ->
        {:hidden, segment, rendered}

      Scope.validate_writable(segment.scope, context.querier_uid) != :ok ->
        {:protected_readonly, segment, rendered}

      true ->
        {:writable_seg, segment, rendered}
    end
  end

  defp segment_visible?(scope, access, disclosure) do
    Access.scope_reachable?(access, scope) and Access.disclosable?(scope, disclosure)
  end

  # Groups writable segments into per-scope units while attaching inter-block
  # pure-whitespace world runs to the adjacent unit so caller edits can match
  # leading/trailing newlines without merging distinct non-world audience blocks.
  defp group_writable_units(classified) do
    {acc_rev, run_rev} =
      Enum.reduce(classified, {[], []}, fn
        {:writable_seg, _seg, _rendered} = writable, {acc, run} ->
          {acc, [writable | run]}

        non_writable, {acc, []} ->
          {[non_writable | acc], []}

        non_writable, {acc, run} ->
          units = writable_run_to_units(Enum.reverse(run))
          {[non_writable | Enum.reverse(units, acc)], []}
      end)

    final_rev =
      case run_rev do
        [] -> acc_rev
        run -> Enum.reverse(writable_run_to_units(Enum.reverse(run)), acc_rev)
      end

    Enum.reverse(final_rev)
  end

  defp writable_run_to_units(run) do
    {units_rev, pending_ws} =
      Enum.reduce(run, {[], ""}, fn {:writable_seg, seg, rendered}, {units, ws} ->
        cond do
          blank_untagged_world?(seg) ->
            {units, ws <> rendered}

          seg.scope == "world" ->
            piece = Markdoc.join_rendered_segments([ws, rendered])

            case units do
              [{:writable_unit, "world", prev_text} | rest] ->
                merged = Markdoc.join_rendered_segments([prev_text, piece])
                {[{:writable_unit, "world", merged} | rest], ""}

              other ->
                {[{:writable_unit, "world", piece} | other], ""}
            end

          true ->
            piece = Markdoc.join_rendered_segments([ws, rendered])
            {[{:writable_unit, seg.scope, piece} | units], ""}
        end
      end)

    units_rev =
      case {units_rev, pending_ws} do
        {units, ""} ->
          units

        {[{:writable_unit, scope, last_text} | rest], ws} ->
          [{:writable_unit, scope, Markdoc.join_rendered_segments([last_text, ws])} | rest]

        {[], ws} ->
          [{:writable_unit, "world", ws}]
      end

    Enum.reverse(units_rev)
  end

  defp blank_untagged_world?(%{scope: "world", text: text} = seg) do
    not Map.get(seg, :tagged, false) and String.trim(text) == ""
  end

  defp blank_untagged_world?(_seg), do: false

  defp expand_unit_calibration_spans(items) do
    {spans_rev, _next_unit_id} =
      Enum.reduce(items, {[], 0}, fn
        {:writable_unit, origin_scope, text}, {acc, unit_id} ->
          unit_spans =
            text
            |> Calibration.split_spans()
            |> Enum.map(fn
              {:text, span_text} -> {:editable, unit_id, origin_scope, span_text, nil}
              {:calibration, fenced} -> {:protected_calibration, unit_id, origin_scope, fenced}
            end)

          {Enum.reverse(unit_spans, acc), unit_id + 1}

        preserved, {acc, unit_id} ->
          {[preserved | acc], unit_id}
      end)

    Enum.reverse(spans_rev)
  end

  defp apply_edits(spans, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, spans}, fn {edit, index}, {:ok, current_spans} ->
      case apply_single_edit(current_spans, edit, index) do
        {:ok, next_spans} -> {:cont, {:ok, next_spans}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_single_edit(spans, %{old_text: old_text, new_text: new_text}, index) do
    editable_matches =
      spans
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:editable, _unit_id, _origin_scope, text, _edit_idx}, span_idx} ->
          Enum.map(:binary.matches(text, old_text), &{span_idx, &1})

        _non_editable ->
          []
      end)

    case editable_matches do
      [{span_idx, {pos, len}}] ->
        {:ok,
         List.update_at(spans, span_idx, fn {:editable, unit_id, origin_scope, text, _prev_idx} ->
           replaced =
             binary_part(text, 0, pos) <>
               new_text <> binary_part(text, pos + len, byte_size(text) - pos - len)

           {:editable, unit_id, origin_scope, replaced, index}
         end)}

      [] ->
        {:error, classify_miss(spans, old_text, index)}

      many ->
        {:error,
         {:edit_ambiguous_match,
          %{
            edit_index: index,
            match_count: length(many),
            hint: "Include more surrounding lines in old_text so it matches exactly once."
          }}}
    end
  end

  defp classify_miss(spans, old_text, index) do
    protected_match? =
      Enum.any?(spans, fn
        {:protected_calibration, _unit_id, _origin_scope, text} ->
          String.contains?(text, old_text)

        {:protected_readonly, _segment, text} ->
          String.contains?(text, old_text)

        _other ->
          false
      end)

    if protected_match? do
      {:edit_protected_span,
       %{
         edit_index: index,
         hint:
           "Protected calibration scorecards and read-only audience sections cannot be edited."
       }}
    else
      {:edit_no_match,
       %{
         edit_index: index,
         hint:
           "old_text was not found in caller-editable content. Call get_page(include_content: true) first."
       }}
    end
  end

  defp validate_edited_document(updated_spans, new_body, original_body, writer_uid) do
    if new_body == original_body do
      {:error, {:edit_invalid, :noop_edit}}
    else
      caller_text = caller_body(updated_spans)

      with :ok <- guard_body_size(new_body),
           :ok <- reject_injected_calibration_markers(updated_spans),
           :ok <- validate_unit_audience_scopes(updated_spans),
           {:ok, caller_segments} <- Markdoc.raw_segments(caller_text),
           :ok <- validate_caller_segments_scopes(caller_segments, writer_uid),
           {:ok, full_segments} <- Markdoc.raw_segments(new_body),
           :ok <- verify_preserved_boundaries(caller_segments, updated_spans, full_segments) do
        verify_edited_calibration_sections(original_body, new_body, full_segments, updated_spans)
      end
    end
  end

  defp reject_injected_calibration_markers(spans) do
    offending =
      Enum.find_value(spans, fn
        {:editable, _unit_id, _origin_scope, text, edit_idx} ->
          if Calibration.contains_fence_marker?(text), do: edit_idx || 0

        _other ->
          nil
      end)

    non_calibration_body =
      spans
      |> Enum.reject(&match?({:protected_calibration, _, _, _}, &1))
      |> render_spans()

    cond do
      is_integer(offending) ->
        {:error, {:edit_protected_span, %{edit_index: offending}}}

      Calibration.contains_fence_marker?(non_calibration_body) ->
        {:error, {:edit_protected_span, %{edit_index: last_edit_index(spans)}}}

      true ->
        :ok
    end
  end

  defp validate_unit_audience_scopes(spans) do
    spans
    |> collect_writable_units()
    |> Enum.reduce_while(:ok, fn {_unit_id, origin_scope, texts, edit_indices}, :ok ->
      case edit_indices do
        [] ->
          {:cont, :ok}

        indices ->
          unit_text = Markdoc.join_rendered_segments(texts)

          case Markdoc.raw_segments(unit_text) do
            {:ok, unit_segments} ->
              stripped? =
                origin_scope != "world" and
                  Enum.any?(unit_segments, &(not &1.tagged and String.trim(&1.text) != ""))

              if stripped? do
                {:halt,
                 {:error,
                  {:edit_stripped_audience_scope,
                   %{
                     edit_index: Enum.max(indices),
                     hint:
                       "Do not strip {% audience %} tags around non-empty text in edit_page; edit inside the block or preserve the audience wrapper."
                   }}}}
              else
                {:cont, :ok}
              end

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp collect_writable_units(spans) do
    {order_rev, by_id} =
      Enum.reduce(spans, {[], %{}}, fn
        {:editable, unit_id, origin_scope, text, edit_idx}, {order, map} ->
          indices = if is_integer(edit_idx), do: [edit_idx], else: []
          acc_unit(order, map, unit_id, origin_scope, text, indices)

        {:protected_calibration, unit_id, origin_scope, text}, {order, map} ->
          acc_unit(order, map, unit_id, origin_scope, text, [])

        _other, acc ->
          acc
      end)

    order_rev
    |> Enum.reverse()
    |> Enum.map(fn unit_id ->
      {origin_scope, texts_rev, indices_rev} = Map.fetch!(by_id, unit_id)
      {unit_id, origin_scope, Enum.reverse(texts_rev), Enum.reverse(indices_rev)}
    end)
  end

  defp acc_unit(order, map, unit_id, origin_scope, text, new_indices) do
    case Map.fetch(map, unit_id) do
      {:ok, {scope, texts_rev, indices_rev}} ->
        {order, Map.put(map, unit_id, {scope, [text | texts_rev], new_indices ++ indices_rev})}

      :error ->
        {[unit_id | order], Map.put(map, unit_id, {origin_scope, [text], new_indices})}
    end
  end

  defp validate_caller_scopes(text, writer_uid) do
    with {:ok, raw_segments} <- Markdoc.raw_segments(text) do
      validate_caller_segments_scopes(raw_segments, writer_uid)
    end
  end

  defp validate_caller_segments_scopes(raw_segments, writer_uid) do
    raw_segments
    |> Enum.filter(&(&1.tagged or String.trim(&1.text) != ""))
    |> Enum.map(& &1.scope)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn scope, :ok ->
      case Scope.validate_writable(scope, writer_uid) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Verifies that edits in caller-editable spans did not open an unclosed
  # CommonMark code fence or HTML block that absorbed a hidden or read-only
  # audience block into another scope.
  defp verify_preserved_boundaries(caller_segments, updated_spans, full_segments) do
    preserved_non_world =
      for span <- updated_spans,
          %{scope: scope, text: text} <- List.wrap(preserved_segment(span)),
          scope != "world",
          do: {scope, text}

    expected = non_world_pairs(caller_segments) ++ preserved_non_world
    actual = non_world_pairs(full_segments)

    if Enum.frequencies(actual) == Enum.frequencies(expected) do
      :ok
    else
      {:error, :edit_corrupts_protected_boundaries}
    end
  end

  defp preserved_segment({:hidden, segment, _rendered}), do: segment
  defp preserved_segment({:protected_readonly, segment, _rendered}), do: segment
  defp preserved_segment(_other), do: nil

  defp non_world_pairs(segments) do
    for %{scope: scope, text: text} <- segments, scope != "world", do: {scope, text}
  end

  defp verify_edited_calibration_sections(original_body, new_body, full_segments, updated_spans) do
    case Calibration.extract_sections(original_body) do
      [] ->
        :ok

      _existing_sections ->
        case verify_calibration_integrity(original_body, new_body, full_segments) do
          :ok ->
            :ok

          {:error, _reason} ->
            {:error, {:edit_protected_span, %{edit_index: last_edit_index(updated_spans)}}}
        end
    end
  end

  defp verify_calibration_integrity(existing_body, new_body) do
    with {:ok, new_segments} <- Markdoc.raw_segments(new_body) do
      verify_calibration_integrity(existing_body, new_body, new_segments)
    end
  end

  defp verify_calibration_integrity(existing_body, new_body, new_segments) do
    existing_sections = Calibration.extract_sections(existing_body)

    with true <- Calibration.extract_sections(new_body) == existing_sections,
         false <-
           Calibration.contains_fence_marker?(Calibration.strip_calibration_section(new_body)),
         {:ok, orig_segments} <- Markdoc.raw_segments(existing_body),
         orig_scoped = scoped_calibration_blocks(orig_segments),
         new_scoped = scoped_calibration_blocks(new_segments),
         true <- length(new_scoped) == length(existing_sections) and new_scoped == orig_scoped,
         :ok <- verify_calibration_block_context(new_segments) do
      :ok
    else
      _invalid -> {:error, {:edit_protected_span, :calibration_section}}
    end
  end

  defp scoped_calibration_blocks(segments) do
    for seg <- segments,
        {:calibration, block} <- Calibration.split_spans(seg.text),
        do: {seg.scope, block}
  end

  defp verify_calibration_block_context(segments) do
    Enum.reduce_while(segments, :ok, fn seg, :ok ->
      parts = Calibration.split_spans(seg.text)
      cal_count = Enum.count(parts, &match?({:calibration, _}, &1))

      if cal_count == 0 do
        {:cont, :ok}
      else
        if valid_calibration_line_boundaries?(parts) and
             valid_calibration_commonmark_context?(parts, cal_count) do
          {:cont, :ok}
        else
          {:halt, {:error, {:edit_protected_span, :calibration_section}}}
        end
      end
    end)
  end

  defp valid_calibration_line_boundaries?(parts) do
    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn
      [{:text, before}, {:calibration, _}] -> String.ends_with?(before, "\n")
      [{:calibration, _}, {:text, after_text}] -> String.starts_with?(after_text, "\n")
      [{:calibration, _}, {:calibration, _}] -> false
      _other -> true
    end)
  end

  defp valid_calibration_commonmark_context?(parts, expected_count) do
    probe =
      ~s(\n\n{% audience scope="#{@calibration_probe_scope}" %}\ncalibration\n{% /audience %}\n\n)

    probed_text =
      Enum.map_join(parts, "", fn
        {:text, text} -> text
        {:calibration, _fenced} -> probe
      end)

    case Markdoc.raw_segments(probed_text) do
      {:ok, probed_segments} ->
        Enum.count(probed_segments, &(&1.scope == @calibration_probe_scope)) == expected_count

      {:error, _reason} ->
        false
    end
  end

  defp last_edit_index(spans) do
    spans
    |> Enum.flat_map(fn
      {:editable, _unit_id, _origin_scope, _text, idx} when is_integer(idx) -> [idx]
      _other -> []
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp render_spans(spans) do
    spans
    |> Enum.map(fn
      {:editable, _unit_id, _origin_scope, text, _edit_idx} -> text
      {:hidden, _segment, text} -> text
      {:protected_calibration, _unit_id, _origin_scope, text} -> text
      {:protected_readonly, _segment, text} -> text
    end)
    |> Markdoc.join_rendered_segments()
  end

  defp caller_body(spans) do
    spans
    |> Enum.flat_map(fn
      {:editable, _unit_id, _origin_scope, text, _edit_idx} -> [text]
      {:protected_calibration, _unit_id, _origin_scope, text} -> [text]
      _excluded -> []
    end)
    |> Markdoc.join_rendered_segments()
  end

  defp visible_text(spans) do
    spans
    |> Enum.flat_map(fn
      {:editable, _unit_id, _origin_scope, text, _edit_idx} -> [text]
      {:hidden, _segment, _text} -> []
      {:protected_calibration, _unit_id, _origin_scope, text} -> [text]
      {:protected_readonly, _segment, text} -> [text]
    end)
    |> Markdoc.join_rendered_segments()
  end

  defp compact_diff(before_text, after_text) do
    before_lines = String.split(before_text, "\n")
    after_lines = String.split(after_text, "\n")

    tagged =
      before_lines
      |> List.myers_difference(after_lines)
      |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)

    changed_indices =
      tagged
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:eq, _line}, _idx} -> []
        {_changed, idx} -> [idx]
      end)

    keep_set =
      Enum.reduce(changed_indices, MapSet.new(), fn idx, acc ->
        Enum.reduce(
          max(idx - @diff_context_lines, 0)..(idx + @diff_context_lines),
          acc,
          &MapSet.put(&2, &1)
        )
      end)

    diff = format_diff_lines(tagged, keep_set)
    Text.truncate_utf8(diff, @max_diff_bytes, "\n... (diff truncated)")
  end

  defp format_diff_lines(tagged, keep_set) do
    {lines_rev, _prev_kept?} =
      tagged
      |> Enum.with_index()
      |> Enum.reduce({[], true}, fn {{op, line}, idx}, {acc, prev_kept?} ->
        if MapSet.member?(keep_set, idx) do
          prefix =
            case op do
              :eq -> "  "
              :del -> "- "
              :ins -> "+ "
            end

          acc = if prev_kept?, do: acc, else: ["@@" | acc]
          {[prefix <> line | acc], true}
        else
          {acc, false}
        end
      end)

    lines_rev |> Enum.reverse() |> Enum.join("\n")
  end

  defp validate_edits(edits) when not is_list(edits) or edits == [],
    do: {:error, {:edit_invalid, :edits_required}}

  defp validate_edits(edits) when length(edits) > @max_edits,
    do: {:error, {:edit_invalid, :too_many_edits}}

  defp validate_edits(edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, acc} ->
      case validate_single_edit(edit, index) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_single_edit(%{"old_text" => raw_old, "new_text" => raw_new}, index)
       when is_binary(raw_old) and is_binary(raw_new) do
    old_text = normalize_newlines(raw_old)
    new_text = normalize_newlines(raw_new)

    cond do
      old_text == "" ->
        {:error, {:edit_invalid, %{edit_index: index, reason: :empty_old_text}}}

      old_text == new_text ->
        {:error, {:edit_invalid, %{edit_index: index, reason: :noop_edit}}}

      byte_size(new_text) > @max_body_bytes ->
        {:error, :body_too_large}

      Calibration.contains_fence_marker?(old_text) or Calibration.contains_fence_marker?(new_text) ->
        {:error, {:edit_protected_span, %{edit_index: index}}}

      true ->
        {:ok, %{old_text: old_text, new_text: new_text}}
    end
  end

  defp validate_single_edit(_invalid, index),
    do: {:error, {:edit_invalid, %{edit_index: index, reason: :invalid_edit_item}}}

  defp reject_calibration_markers(content) do
    if Calibration.contains_fence_marker?(content),
      do: {:error, {:edit_protected_span, :calibration_section}},
      else: :ok
  end

  defp preserve_existing_calibration(existing_body, new_body) do
    case Calibration.extract_sections(existing_body) do
      [] ->
        with :ok <- reject_calibration_markers(new_body), do: {:ok, new_body}

      existing_sections ->
        if not Calibration.contains_fence_marker?(new_body) do
          {:ok, Enum.reduce(existing_sections, new_body, &Calibration.append_section(&2, &1))}
        else
          with :ok <- verify_calibration_integrity(existing_body, new_body), do: {:ok, new_body}
        end
    end
  end

  # When replacing a page without an explicit `scope` parameter, preserve the
  # page's existing single scope over untagged prose (or fall back to
  # `context.default_write_scope` when the page had no prose) so a private or
  # group page never silently widens to `world`.
  defp resolve_replace_body(existing_body, content, explicit_scope, _context)
       when is_binary(explicit_scope) do
    apply_replace_scope(existing_body, content, explicit_scope)
  end

  defp resolve_replace_body(existing_body, content, nil, context) do
    with {:ok, raw_segments} <- Markdoc.raw_segments(content) do
      existing_prose = Calibration.strip_calibration_section(existing_body)

      case Markdoc.scopes(existing_prose) do
        {:ok, [single_scope]} ->
          apply_replace_scope(existing_body, content, single_scope)

        {:ok, []} ->
          with {:ok, scope} <- Context.write_scope(nil, context) do
            apply_replace_scope(existing_body, content, scope)
          end

        {:ok, [_first, _second | _rest]} ->
          if String.trim(content) == "" or Enum.any?(raw_segments, & &1.tagged) do
            {:ok, content}
          else
            {:error,
             {:mixed_scopes_require_explicit_tags_or_scope,
              %{
                hint:
                  "This page mixes multiple audience scopes. Preserve {% audience %} tags from get_page(include_content: true), pass an explicit scope, or use edit_page."
              }}}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp apply_replace_scope(existing_body, content, scope) do
    if not Calibration.contains_fence_marker?(content) do
      Markdoc.apply_default_scope(content, scope)
    else
      prose = Calibration.strip_calibration_section(content)

      with {:ok, _raw} <- Markdoc.raw_segments(content),
           {:ok, prose_segments} <- Markdoc.raw_segments(prose) do
        cond do
          scope == "world" or
              Enum.all?(prose_segments, &(&1.tagged or String.trim(&1.text) == "")) ->
            {:ok, content}

          verify_calibration_integrity(existing_body, content) == :ok ->
            Markdoc.apply_default_scope(prose, scope)

          true ->
            {:ok, content}
        end
      end
    end
  end

  defp guard_body_size(body) when byte_size(body) <= @max_body_bytes, do: :ok
  defp guard_body_size(_body), do: {:error, :body_too_large}

  defp normalize_newlines(text) when is_binary(text), do: String.replace(text, "\r\n", "\n")

  defp build_replace_attrs(locked, expected_revision, final_body, opts) do
    base = %{
      body: final_body,
      title: opts.title || locked.title,
      expected_content_hash: expected_revision
    }

    base =
      case opts.subtype do
        :unchanged -> base
        {:set, subtype} -> Map.put(base, :subtype, subtype)
      end

    case opts.tags do
      :unchanged -> base
      {:set, tags} -> Map.put(base, :tags, tags)
    end
  end

  defp guard_non_empty(_content, true), do: :ok

  defp guard_non_empty(content, false) do
    if String.trim(content) == "", do: {:error, :empty_content_not_allowed}, else: :ok
  end

  defp add_aliases(_slug, []), do: :ok

  defp add_aliases(slug, aliases) do
    Enum.reduce_while(aliases, :ok, fn alias_text, :ok ->
      case Links.add_alias(slug, alias_text) do
        {:ok, _added} -> {:cont, :ok}
        {:error, :blank_alias} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp optional_explicit_scope(nil, _context), do: {:ok, nil}
  defp optional_explicit_scope("", _context), do: {:ok, nil}
  defp optional_explicit_scope(explicit, context), do: Context.write_scope(explicit, context)

  defp required_trimmed(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:missing, key}}
    end
  end

  defp required_binary(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing, key}}
    end
  end

  defp optional_trimmed(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, Ankole.Attrs.optional_text(value)}
      _other -> {:error, {:invalid, key}}
    end
  end

  defp fetch_optional_trimmed(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, :unchanged}
      {:ok, nil} -> {:ok, {:set, nil}}
      {:ok, value} when is_binary(value) -> {:ok, {:set, Ankole.Attrs.optional_text(value)}}
      {:ok, _other} -> {:error, {:invalid, key}}
    end
  end

  defp optional_string_list(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, Enum.map(list, &String.trim/1)},
          else: {:error, {:invalid, key}}

      _other ->
        {:error, {:invalid, key}}
    end
  end

  defp fetch_optional_string_list(params, key) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, :unchanged}

      {:ok, nil} ->
        {:ok, :unchanged}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, {:set, Enum.map(list, &String.trim/1)}},
          else: {:error, {:invalid, key}}

      {:ok, _other} ->
        {:error, {:invalid, key}}
    end
  end
end
