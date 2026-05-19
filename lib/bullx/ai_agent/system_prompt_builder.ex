defmodule BullX.AIAgent.SystemPromptBuilder do
  @moduledoc """
  Pure deterministic renderer for AIAgent system prompt sections.
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
      priority: 0,
      content: nil,
      provenance: %{}
    ]
  end

  @type section :: Section.t() | map()
  @type render_error :: {:system_prompt_builder, atom(), map()}

  @spec render([section()], keyword()) :: {:ok, map()} | {:error, render_error()}
  def render(sections, opts \\ [])

  def render(sections, opts) when is_list(sections) and is_list(opts) do
    started = System.monotonic_time()

    with {:ok, normalized} <- normalize_sections(sections),
         :ok <- reject_duplicate_ids(normalized),
         {:ok, rendered_sections} <- rendered_sections(normalized),
         result <- build_result(rendered_sections, normalized),
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

  defp valid_cache_break_reason?(%Section{stability: :stable}), do: true

  defp valid_cache_break_reason?(%Section{cache_break_reason: nil}), do: true

  defp valid_cache_break_reason?(%Section{cache_break_reason: reason}) when is_binary(reason) do
    String.valid?(reason) and byte_size(reason) <= 120 and not String.contains?(reason, <<0>>) and
      not String.contains?(reason, "\r")
  end

  defp valid_cache_break_reason?(_section), do: false

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
        "raw_target_session_entry",
        "target_session_entry",
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
        %{section: section, text: section_text(section), size: byte_size(section_text(section))}
      end)

    {:ok, rendered}
  end

  defp stability_order(:stable), do: 0
  defp stability_order(:volatile), do: 1

  defp section_text(%Section{content: content}) when is_binary(content), do: content

  defp section_text(%Section{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(&part_text/1)
    |> Enum.join("\n\n")
  end

  defp part_text(%ContentPart{text: text}), do: text
  defp part_text(%{text: text}), do: text
  defp part_text(%{"text" => text}), do: text

  defp build_result(rendered_sections, all_sections) do
    system_text =
      rendered_sections
      |> Enum.map(& &1.text)
      |> Enum.join("\n\n")

    stable_sections = Enum.filter(rendered_sections, &(&1.section.stability == :stable))
    stable_prefix_text = stable_prefix_text(stable_sections)
    stable_size = byte_size(stable_prefix_text)
    total_size = byte_size(system_text)

    %{
      system_content: system_content_parts(rendered_sections),
      system_text: system_text,
      stable_prefix: %{
        last_stable_section_id: last_stable_section_id(stable_sections),
        stable_section_count: length(stable_sections),
        content_part_index: stable_content_part_index(stable_sections),
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

  defp stable_prefix_text(stable_sections),
    do: stable_sections |> Enum.map(& &1.text) |> Enum.join("\n\n")

  defp system_content_parts([]), do: []

  defp system_content_parts([first | rest]) do
    [ContentPart.text(first.text) | Enum.map(rest, &ContentPart.text("\n\n" <> &1.text))]
  end

  defp omitted_section_ids(sections) do
    sections
    |> Enum.filter(&is_nil(&1.content))
    |> Enum.map(& &1.id)
  end

  defp last_stable_section_id([]), do: nil

  defp last_stable_section_id(stable_sections),
    do: (stable_sections |> List.last()).section.id

  defp stable_content_part_index([]), do: nil
  defp stable_content_part_index(stable_sections), do: length(stable_sections) - 1

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
