defmodule Ankole.Files.Path do
  @moduledoc """
  Validates drive paths.

  This module calls no domain module, so a resource can call it from its
  declarations (see `mix ankole.compile_cycles`).
  """

  @max_path_bytes 1024
  @max_segment_bytes 255

  @doc "The maximum size in bytes of one path segment."
  @spec max_segment_bytes() :: pos_integer()
  def max_segment_bytes, do: @max_segment_bytes

  @doc """
  Validates a drive path for a new write or rename and returns it unchanged.

  A path is relative, at most #{@max_path_bytes} bytes, and every segment is
  1 to #{@max_segment_bytes} bytes, not `.` or `..`, and free of control,
  line/paragraph separator, and Unicode bidirectional control codepoints.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, {:invalid_path, term()}}
  def normalize(path) when is_binary(path) do
    segments = String.split(path, "/")

    valid? =
      String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
        Enum.all?(segments, &valid_segment?/1)

    if valid?, do: {:ok, path}, else: {:error, {:invalid_path, path}}
  end

  def normalize(path), do: {:error, {:invalid_path, path}}

  @doc """
  Validates a stored drive path for reading, moving away, or deleting legacy entries.

  Preserves addressability of historical nodes whose names predate Bidi/control
  rejection while still rejecting NUL bytes, empty segments, `.`, and `..`.
  """
  @spec normalize_existing(term()) :: {:ok, String.t()} | {:error, {:invalid_path, term()}}
  def normalize_existing(path) when is_binary(path) do
    segments = String.split(path, "/")

    valid? =
      String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
        not String.contains?(path, <<0>>) and
        Enum.all?(segments, &valid_existing_segment?/1)

    if valid?, do: {:ok, path}, else: {:error, {:invalid_path, path}}
  end

  def normalize_existing(path), do: {:error, {:invalid_path, path}}

  @doc "Returns true when `segment` is a valid new Drive node or path segment name."
  @spec valid_segment?(term()) :: boolean()
  def valid_segment?(segment) when is_binary(segment) do
    String.valid?(segment) and
      segment not in ["", ".", ".."] and
      byte_size(segment) in 1..@max_segment_bytes and
      not String.contains?(segment, "/") and
      not contains_control_or_bidi?(segment)
  end

  def valid_segment?(_segment), do: false

  @doc "Returns true when `text` contains any Unicode bidirectional control or isolate codepoint."
  @spec contains_bidi?(term()) :: boolean()
  def contains_bidi?(text) when is_binary(text) do
    if String.valid?(text), do: do_contains_bidi?(text), else: false
  end

  def contains_bidi?(_text), do: false

  @doc "Returns true when `text` contains invalid UTF-8, C0/DEL/C1 controls, line separators, or Bidi codepoints."
  @spec contains_control_or_bidi?(term()) :: boolean()
  def contains_control_or_bidi?(text) when is_binary(text) do
    if String.valid?(text), do: do_contains_control_or_bidi?(text), else: true
  end

  def contains_control_or_bidi?(_text), do: true

  @doc "Normalizes valid UTF-8 text to NFC and strips all Unicode bidirectional control codepoints."
  @spec strip_bidi(term()) :: String.t()
  def strip_bidi(text) when is_binary(text) do
    text
    |> nfc()
    |> do_strip_bidi(<<>>)
  end

  def strip_bidi(_text), do: ""

  @doc "Strips Unicode bidirectional and control/line-separator codepoints, preserving spaces and the original form of other Unicode characters."
  @spec strip_bidi_and_controls(term()) :: String.t()
  def strip_bidi_and_controls(text) when is_binary(text) do
    text
    |> scrub_utf8()
    |> do_strip_bidi(<<>>)
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]+/u, "")
  end

  def strip_bidi_and_controls(_text), do: ""

  @doc "Sanitizes untrusted single-line label or summary text against Bidi overrides and line-breaking controls."
  @spec sanitize_inline_text(term()) :: String.t()
  def sanitize_inline_text(text) when is_binary(text) do
    text
    |> strip_bidi()
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]+/u, " ")
    |> String.trim()
  end

  def sanitize_inline_text(_text), do: ""

  @doc "Makes an external filename safe as one Drive path segment."
  @spec file_name(term()) :: String.t()
  def file_name(name) when is_binary(name) do
    name
    |> strip_bidi()
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}\/\\]+/u, "_")
    |> String.trim()
    |> truncate_bytes(@max_segment_bytes)
    |> case do
      name when name in ["", ".", ".."] -> "file"
      name -> name
    end
  end

  def file_name(_name), do: "file"

  @doc "Sanitizes each segment of a relative attachment or display path against Bidi overrides and controls."
  @spec sanitize_display_path(term()) :: String.t()
  def sanitize_display_path(path) when is_binary(path) do
    segments =
      path
      |> nfc()
      |> String.replace("\\", "/")
      |> String.split("/", trim: true)
      |> Enum.reject(&(&1 in [".", ".."]))
      |> Enum.map(&file_name/1)

    case segments do
      [] ->
        "file"

      segments ->
        joined = Enum.join(segments, "/")
        if byte_size(joined) <= @max_path_bytes, do: joined, else: List.last(segments)
    end
  end

  def sanitize_display_path(_path), do: "file"

  @doc false
  def nfc(text) when is_binary(text) do
    clean = scrub_utf8(text)

    case :unicode.characters_to_nfc_binary(clean) do
      normalized when is_binary(normalized) -> normalized
      _ -> clean
    end
  end

  defp scrub_utf8(text) do
    if String.valid?(text) do
      text
    else
      text
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk -> if String.valid?(chunk), do: chunk, else: "" end)
    end
  end

  defp valid_existing_segment?(segment),
    do: segment not in ["", ".", ".."] and byte_size(segment) <= @max_segment_bytes

  defp bidi_codepoint?(cp) do
    cp == 0x061C or
      (cp >= 0x200E and cp <= 0x200F) or
      (cp >= 0x202A and cp <= 0x202E) or
      (cp >= 0x2066 and cp <= 0x2069)
  end

  defp control_codepoint?(cp) do
    cp <= 0x001F or
      (cp >= 0x007F and cp <= 0x009F) or
      cp == 0x2028 or
      cp == 0x2029
  end

  defp do_contains_bidi?(<<>>), do: false

  defp do_contains_bidi?(<<cp::utf8, rest::binary>>) do
    bidi_codepoint?(cp) or do_contains_bidi?(rest)
  end

  defp do_contains_control_or_bidi?(<<>>), do: false

  defp do_contains_control_or_bidi?(<<cp::utf8, rest::binary>>) do
    bidi_codepoint?(cp) or control_codepoint?(cp) or do_contains_control_or_bidi?(rest)
  end

  defp do_strip_bidi(<<>>, acc), do: acc

  defp do_strip_bidi(<<cp::utf8, rest::binary>>, acc) do
    if bidi_codepoint?(cp) do
      do_strip_bidi(rest, acc)
    else
      do_strip_bidi(rest, <<acc::binary, cp::utf8>>)
    end
  end

  defp do_strip_bidi(<<byte, rest::binary>>, acc) do
    do_strip_bidi(rest, <<acc::binary, byte>>)
  end

  defp truncate_bytes(text, maximum) when byte_size(text) <= maximum, do: text

  defp truncate_bytes(text, maximum) do
    <<prefix::binary-size(^maximum), _::binary>> = text
    if String.valid?(prefix), do: prefix, else: truncate_bytes(prefix, maximum - 1)
  end
end
