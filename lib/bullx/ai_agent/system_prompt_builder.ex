defmodule BullX.AIAgent.SystemPromptBuilder do
  @moduledoc """
  Pure deterministic renderer for AIAgent system prompt sections.

  Anyone who has run an OpenClaw / Hermes-style agent for any length of time
  has hit the same wall: rising token costs, prompt-cache misses, and rate
  limits caused by long sessions that re-inject growing memory + skill
  files + history on every model call. The Hermes design responds with a
  bounded "MEMORY.md ≈ 800 tokens / USER.md ≈ 500 tokens" budget; OpenClaw
  responds with session pruning. BullX's response lives in this module: each
  contributor declares its sections with an explicit **stability** tag.

  At render time, sections are sorted so all `:stable` sections sit before
  any `:volatile` one, forming a contiguous **stable prefix**. The output
  exposes that prefix's byte offset (`stable_prefix.byte_offset`) so
  downstream prompt-cache hints (`BullX.AIAgent.Compression.apply_prompt_cache_hints/2`)
  can tell the provider exactly where to anchor the cache. Volatile content
  (the live branch, recent observations, time-aware data) is always
  appended *after* the cache anchor, so it never invalidates the prefix on
  the next call.

  This makes prompt caching a structural property of how prompts are
  assembled, not a heuristic that hopes the prefix happens to stay stable.
  """

  alias ReqLLM.Message.ContentPart

  defmodule Section do
    @moduledoc false

    @enforce_keys [:id, :kind, :stability, :content]
    defstruct [
      :id,
      :kind,
      :stability,
      :cache_break_reason,
      :tag,
      priority: 0,
      content: nil,
      provenance: %{}
    ]
  end

  defmodule Segment do
    @moduledoc false

    @enforce_keys [:type]
    defstruct [
      :type,
      :id,
      :content,
      :render
    ]
  end

  @type section :: Section.t() | map()
  @type segment :: Segment.t()
  @type render_error :: {:system_prompt_builder, atom(), map()}

  @spec text(String.t()) :: segment()
  def text(content) when is_binary(content), do: %Segment{type: :text, content: content}

  @spec optional(String.t(), term(), (term() -> String.t())) :: segment()
  def optional(id, content, render) when is_binary(id) and is_function(render, 1),
    do: %Segment{type: :optional, id: id, content: content, render: render}

  @spec sections() :: segment()
  def sections, do: %Segment{type: :sections}

  @spec render([section()], keyword()) :: {:ok, map()} | {:error, render_error()}
  def render(sections, opts \\ [])

  def render(sections, opts) when is_list(sections) and is_list(opts) do
    started = System.monotonic_time()

    with {:ok, normalized} <- normalize_sections(sections),
         :ok <- reject_duplicate_ids(normalized),
         {:ok, rendered_sections} <- rendered_sections(normalized),
         {:ok, rendered_units} <- rendered_units(rendered_sections, Keyword.get(opts, :template)),
         :ok <- validate_stable_prefix(rendered_units),
         result <- build_result(rendered_units, rendered_sections, normalized),
         result <- add_build_duration(result, started),
         :ok <- validate_size_cap(result, opts) do
      emit(:built, result)
      {:ok, result}
    else
      {:error, {_tag, _reason, _meta} = error} ->
        emit_error(error)
        {:error, error}
    end
  end

  def render(_sections, _opts) do
    error = {:system_prompt_builder, :invalid_sections, %{}}
    emit_error(error)
    {:error, error}
  end

  defp normalize_sections(sections) do
    sections
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {section, index}, {:ok, acc} ->
      case normalize_section(section, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason, meta} -> {:halt, {:error, {:system_prompt_builder, reason, meta}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_section(%Section{} = section, index), do: validate_section(section, index)

  defp normalize_section(%{} = section, index) do
    with {:ok, id} <- fetch_required(section, :id),
         {:ok, kind} <- fetch_required(section, :kind),
         {:ok, stability} <- fetch_required(section, :stability),
         {:ok, content} <- fetch_required(section, :content) do
      struct =
        %Section{
          id: id,
          kind: kind,
          stability: stability,
          cache_break_reason: field_value(section, :cache_break_reason),
          tag: field_value(section, :tag),
          priority: optional_field_value(section, :priority, 0),
          content: content,
          provenance: optional_field_value(section, :provenance, %{})
        }

      validate_section(struct, index)
    else
      {:error, field} ->
        {:error, :missing_required_field, %{input_index: index, field: to_string(field)}}
    end
  end

  defp normalize_section(_section, index),
    do: {:error, :invalid_section, %{input_index: index}}

  defp validate_section(%Section{} = section, index) do
    cond do
      not is_binary(section.id) or section.id == "" ->
        {:error, :invalid_section_id, %{input_index: index}}

      not is_atom(section.kind) ->
        {:error, :invalid_kind, %{section_id: section.id, input_index: index}}

      section.stability not in [:stable, :volatile] ->
        {:error, :invalid_stability, %{section_id: section.id, input_index: index}}

      not is_integer(section.priority) ->
        {:error, :invalid_priority, %{section_id: section.id, input_index: index}}

      not valid_cache_break_reason?(section) ->
        {:error, :invalid_cache_break_reason, %{section_id: section.id, input_index: index}}

      not valid_tag?(section.tag) ->
        {:error, :invalid_tag, %{section_id: section.id, input_index: index}}

      not is_map(section.provenance) ->
        {:error, :invalid_provenance, %{section_id: section.id, input_index: index}}

      true ->
        validate_content(section, index)
    end
  end

  defp field_value(map, field) do
    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      Map.has_key?(map, Atom.to_string(field)) -> Map.fetch!(map, Atom.to_string(field))
      true -> nil
    end
  end

  defp optional_field_value(map, field, default) do
    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      Map.has_key?(map, Atom.to_string(field)) -> Map.fetch!(map, Atom.to_string(field))
      true -> default
    end
  end

  defp fetch_required(map, field) do
    cond do
      Map.has_key?(map, field) -> {:ok, Map.fetch!(map, field)}
      Map.has_key?(map, Atom.to_string(field)) -> {:ok, Map.fetch!(map, Atom.to_string(field))}
      true -> {:error, field}
    end
  end

  defp valid_cache_break_reason?(%Section{stability: :stable, cache_break_reason: nil}), do: true

  defp valid_cache_break_reason?(%Section{stability: :stable, cache_break_reason: ""}), do: true

  defp valid_cache_break_reason?(%Section{stability: :volatile, cache_break_reason: reason})
       when is_binary(reason) do
    reason = String.trim(reason)

    reason != "" and String.valid?(reason) and byte_size(reason) <= 120 and
      not String.contains?(reason, <<0>>) and not String.contains?(reason, "\r")
  end

  defp valid_cache_break_reason?(_section), do: false

  defp valid_tag?(nil), do: true

  defp valid_tag?(tag) when is_binary(tag) do
    String.match?(tag, ~r/^[a-z][a-z0-9_-]*$/)
  end

  defp valid_tag?(_tag), do: false

  defp validate_content(%Section{content: nil} = section, _index), do: {:ok, section}

  defp validate_content(%Section{content: content} = section, index) when is_binary(content) do
    cond do
      content == "" ->
        {:error, :empty_content, %{section_id: section.id, input_index: index}}

      not String.valid?(content) ->
        {:error, :invalid_content, %{section_id: section.id, input_index: index}}

      String.contains?(content, <<0>>) ->
        {:error, :invalid_content, %{section_id: section.id, input_index: index}}

      String.contains?(content, "\r") ->
        {:error, :invalid_content, %{section_id: section.id, input_index: index}}

      true ->
        {:ok, section}
    end
  end

  defp validate_content(%Section{content: content} = section, index) when is_list(content) do
    case validate_content_parts(content) do
      :ok -> {:ok, section}
      {:error, reason} -> {:error, reason, %{section_id: section.id, input_index: index}}
    end
  end

  defp validate_content(%Section{} = section, index),
    do: {:error, :invalid_content, %{section_id: section.id, input_index: index}}

  defp validate_content_parts([]), do: {:error, :empty_content}

  defp validate_content_parts(parts) do
    Enum.reduce_while(parts, :ok, fn
      part, :ok ->
        case normalize_content_part(part) do
          {:ok, %ContentPart{type: :text, text: text, metadata: metadata}} ->
            cond do
              not is_binary(text) or text == "" -> {:halt, {:error, :empty_content}}
              not String.valid?(text) -> {:halt, {:error, :invalid_content}}
              String.contains?(text, <<0>>) -> {:halt, {:error, :invalid_content}}
              String.contains?(text, "\r") -> {:halt, {:error, :invalid_content}}
              forbidden_metadata?(metadata) -> {:halt, {:error, :forbidden_content_metadata}}
              true -> {:cont, :ok}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp normalize_content_part(%ContentPart{} = part), do: {:ok, part}

  defp normalize_content_part(%{type: :text, text: text} = part) do
    if forbidden_content_part_shape?(part, [:type, :text, :metadata]) do
      {:error, :forbidden_content_metadata}
    else
      {:ok, %ContentPart{type: :text, text: text, metadata: Map.get(part, :metadata, %{})}}
    end
  end

  defp normalize_content_part(%{"type" => "text", "text" => text} = part) do
    if forbidden_content_part_shape?(part, ["type", "text", "metadata"]) do
      {:error, :forbidden_content_metadata}
    else
      {:ok, %ContentPart{type: :text, text: text, metadata: Map.get(part, "metadata", %{})}}
    end
  end

  defp normalize_content_part(_part), do: {:error, :invalid_content_part}

  defp forbidden_content_part_shape?(part, allowed_keys) do
    part
    |> Map.drop(allowed_keys)
    |> forbidden_metadata?()
  end

  defp forbidden_metadata?(metadata) when is_map(metadata) do
    forbidden =
      MapSet.new([
        "credential",
        "credentials",
        "secret",
        "api_key",
        "signed_token",
        "session_secret",
        "raw_provider_payload",
        "raw_cloud_event",
        "raw_stream_chunk",
        "private_policy",
        "raw_mailbox_entry",
        "mailbox_entry",
        "raw_side_channel_entry",
        "side_channel_entry"
      ])

    metadata
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.any?(&MapSet.member?(forbidden, &1))
  end

  defp forbidden_metadata?(_metadata), do: true

  defp reject_duplicate_ids(sections) do
    duplicate =
      sections
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.find(fn {_id, count} -> count > 1 end)

    case duplicate do
      nil -> :ok
      {id, _count} -> {:error, {:system_prompt_builder, :duplicate_section_id, %{section_id: id}}}
    end
  end

  defp rendered_sections(sections) do
    rendered =
      sections
      |> Enum.with_index()
      |> Enum.reject(fn {%Section{content: content}, _index} -> is_nil(content) end)
      |> Enum.sort_by(fn {%Section{} = section, index} ->
        {stability_order(section.stability), section.priority, index}
      end)
      |> Enum.map(fn {%Section{} = section, _index} ->
        text = section_text(section)
        %{type: :section, id: section.id, section: section, text: text, size: byte_size(text)}
      end)

    {:ok, rendered}
  end

  defp stability_order(:stable), do: 0
  defp stability_order(:volatile), do: 1

  defp section_text(%Section{} = section),
    do: wrap_section(section, section_content_text(section))

  defp section_content_text(%Section{content: content}) when is_binary(content), do: content

  defp section_content_text(%Section{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(&part_text/1)
    |> Enum.join("\n\n")
  end

  defp part_text(%ContentPart{text: text}), do: text
  defp part_text(%{text: text}), do: text
  defp part_text(%{"text" => text}), do: text

  defp wrap_section(%Section{tag: nil}, text), do: text

  defp wrap_section(%Section{tag: tag}, text) do
    IO.iodata_to_binary(["<", tag, ">\n", text, "\n</", tag, ">"])
  end

  defp rendered_units(rendered_sections, nil),
    do: {:ok, Enum.map(rendered_sections, &section_unit/1)}

  defp rendered_units(rendered_sections, template) when is_list(template) do
    sorted_sections = rendered_sections

    template
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn segment, {:ok, acc, used} ->
      case render_segment(segment, sorted_sections, used) do
        {:ok, rendered, used} -> {:cont, {:ok, acc ++ rendered, used}}
        {:error, reason, meta} -> {:halt, {:error, {:system_prompt_builder, reason, meta}}}
      end
    end)
    |> case do
      {:ok, units, used} ->
        unused =
          sorted_sections
          |> Enum.reject(&MapSet.member?(used, &1.section.id))
          |> Enum.map(&section_unit/1)

        {:ok, units ++ unused}

      {:error, _reason} = error ->
        error
    end
  end

  defp rendered_units(_rendered_sections, _template),
    do: {:error, {:system_prompt_builder, :invalid_template, %{}}}

  defp render_segment(%Segment{type: :text, content: content}, _sections, used)
       when is_binary(content) do
    case normalize_template_text(content) do
      {:ok, nil} -> {:ok, [], used}
      {:ok, text} -> {:ok, [template_unit(text)], used}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  defp render_segment(
         %Segment{type: :optional, id: id, content: content, render: render},
         _sections,
         used
       )
       when is_binary(id) and is_function(render, 1) do
    case blank?(content) do
      true ->
        {:ok, [], used}

      false ->
        content
        |> render.()
        |> normalize_template_text()
        |> case do
          {:ok, nil} -> {:ok, [], used}
          {:ok, text} -> {:ok, [template_unit(text)], used}
          {:error, reason} -> {:error, reason, %{template_segment_id: id}}
        end
    end
  end

  defp render_segment(%Segment{type: :sections}, sections, used) do
    units =
      sections
      |> Enum.reject(&MapSet.member?(used, &1.section.id))
      |> Enum.map(&section_unit/1)

    next_used = Enum.reduce(sections, used, &MapSet.put(&2, &1.section.id))
    {:ok, units, next_used}
  end

  defp render_segment(_segment, _sections, _used),
    do: {:error, :invalid_template_segment, %{}}

  defp normalize_template_text(content) when is_binary(content) do
    cond do
      not String.valid?(content) ->
        {:error, :invalid_template_content}

      String.contains?(content, <<0>>) ->
        {:error, :invalid_template_content}

      String.contains?(content, "\r") ->
        {:error, :invalid_template_content}

      true ->
        content
        |> String.trim()
        |> case do
          "" -> {:ok, nil}
          text -> {:ok, text}
        end
    end
  end

  defp normalize_template_text(_content), do: {:error, :invalid_template_content}

  defp blank?(nil), do: true
  defp blank?(content) when is_binary(content), do: String.trim(content) == ""
  defp blank?(_content), do: false

  defp template_unit(text),
    do: %{type: :template, text: text, size: byte_size(text), stability: :stable}

  defp section_unit(%{section: %Section{} = section} = rendered) do
    rendered
    |> Map.put(:stability, section.stability)
    |> Map.put(:type, :section)
  end

  defp validate_stable_prefix(units) do
    units
    |> Enum.reduce_while(:stable, fn
      %{stability: :stable}, :volatile_seen ->
        {:halt, {:error, {:system_prompt_builder, :stable_after_volatile, %{}}}}

      %{stability: :volatile}, _state ->
        {:cont, :volatile_seen}

      %{stability: :stable}, :stable ->
        {:cont, :stable}
    end)
    |> case do
      :stable -> :ok
      :volatile_seen -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp build_result(rendered_units, rendered_sections, all_sections) do
    system_text =
      rendered_units
      |> Enum.map(& &1.text)
      |> Enum.join("\n\n")

    stable_units = Enum.filter(rendered_units, &(&1.stability == :stable))
    stable_sections = Enum.filter(rendered_sections, &(&1.section.stability == :stable))
    stable_prefix_text = stable_prefix_text(stable_units)
    stable_size = byte_size(stable_prefix_text)
    total_size = byte_size(system_text)

    %{
      system_content: system_content(system_text),
      system_text: system_text,
      stable_prefix: %{
        last_stable_section_id: last_stable_section_id(stable_units),
        stable_section_count: length(stable_units),
        content_part_index: stable_content_part_index(stable_units),
        byte_offset: stable_size
      },
      diagnostics: %{
        rendered_section_ids: Enum.map(rendered_sections, & &1.section.id),
        omitted_section_ids: omitted_section_ids(all_sections),
        section_sizes: Map.new(rendered_sections, &{&1.section.id, &1.size}),
        section_kinds: Map.new(rendered_sections, &{&1.section.id, &1.section.kind}),
        section_stabilities: Map.new(rendered_sections, &{&1.section.id, &1.section.stability}),
        provenance_keys:
          Map.new(rendered_sections, fn rendered ->
            {rendered.section.id,
             rendered.section.provenance |> Map.keys() |> Enum.map(&to_string/1)}
          end),
        cache_break_reasons_present:
          rendered_sections
          |> Enum.filter(fn rendered ->
            rendered.section.stability == :volatile and
              is_binary(rendered.section.cache_break_reason) and
              rendered.section.cache_break_reason != ""
          end)
          |> Enum.map(& &1.section.id),
        total_size: total_size,
        stable_prefix_size: stable_size,
        volatile_suffix_size: total_size - stable_size,
        rendered_stable_section_count: length(stable_sections),
        rendered_volatile_section_count:
          Enum.count(rendered_sections, &(&1.section.stability == :volatile))
      }
    }
  end

  defp add_build_duration(result, started) do
    duration_native = System.monotonic_time() - started
    duration_us = System.convert_time_unit(duration_native, :native, :microsecond)
    put_in(result, [:diagnostics, :build_duration_us], duration_us)
  end

  defp stable_prefix_text([]), do: ""

  defp stable_prefix_text(stable_units),
    do: stable_units |> Enum.map(& &1.text) |> Enum.join("\n\n")

  defp system_content(""), do: []
  defp system_content(system_text), do: [ContentPart.text(system_text)]

  defp omitted_section_ids(sections) do
    sections
    |> Enum.filter(&is_nil(&1.content))
    |> Enum.map(& &1.id)
  end

  defp last_stable_section_id([]), do: nil

  defp last_stable_section_id(stable_units) do
    case List.last(stable_units) do
      %{section: %Section{id: id}} -> id
      %{type: :template} -> nil
    end
  end

  defp stable_content_part_index([]), do: nil
  defp stable_content_part_index(_stable_units), do: 0

  defp validate_size_cap(result, opts) do
    case Keyword.get(opts, :max_total_bytes) do
      nil ->
        :ok

      max when is_integer(max) and result.diagnostics.total_size <= max ->
        :ok

      max when is_integer(max) ->
        {:error,
         {:system_prompt_builder, :system_prompt_size_exceeded,
          %{total_size: result.diagnostics.total_size, max_total_bytes: max}}}
    end
  end

  defp emit(:built, result) do
    :telemetry.execute(
      [:bullx, :ai_agent, :system_prompt, :built],
      %{
        total_size: result.diagnostics.total_size,
        stable_prefix_size: result.diagnostics.stable_prefix_size,
        volatile_suffix_size: result.diagnostics.volatile_suffix_size,
        rendered_stable_section_count: result.diagnostics.rendered_stable_section_count,
        rendered_volatile_section_count: result.diagnostics.rendered_volatile_section_count,
        omitted_section_count: length(result.diagnostics.omitted_section_ids),
        build_duration_us: result.diagnostics.build_duration_us
      },
      %{
        rendered_section_ids: result.diagnostics.rendered_section_ids,
        omitted_section_ids: result.diagnostics.omitted_section_ids,
        section_kinds: result.diagnostics.section_kinds,
        section_stabilities: result.diagnostics.section_stabilities,
        provenance_keys: result.diagnostics.provenance_keys,
        cache_break_reasons_present: result.diagnostics.cache_break_reasons_present
      }
    )
  end

  defp emit_error({:system_prompt_builder, reason, metadata}) do
    :telemetry.execute(
      [:bullx, :ai_agent, :system_prompt, :error],
      %{},
      error_telemetry_metadata(reason, metadata)
    )
  end

  defp error_telemetry_metadata(reason, metadata) do
    %{
      reason: reason,
      section_id: metadata[:section_id] || metadata["section_id"],
      kind: metadata[:kind] || metadata["kind"],
      stability: metadata[:stability] || metadata["stability"],
      provenance_keys:
        metadata
        |> Map.get(:provenance, Map.get(metadata, "provenance", %{}))
        |> case do
          provenance when is_map(provenance) -> provenance |> Map.keys() |> Enum.map(&to_string/1)
          _other -> []
        end
    }
  end
end
