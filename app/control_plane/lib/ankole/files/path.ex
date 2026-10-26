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
  Validates a drive path and returns it unchanged.

  A path is relative, at most #{@max_path_bytes} bytes, and every segment is
  1 to #{@max_segment_bytes} bytes, not `.` or `..`, and free of NUL bytes.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, {:invalid_path, term()}}
  def normalize(path) when is_binary(path) do
    segments = String.split(path, "/")

    valid? =
      String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
        not String.contains?(path, <<0>>) and
        Enum.all?(segments, &valid_segment?/1)

    if valid?, do: {:ok, path}, else: {:error, {:invalid_path, path}}
  end

  def normalize(path), do: {:error, {:invalid_path, path}}

  defp valid_segment?(segment),
    do: segment not in ["", ".", ".."] and byte_size(segment) <= @max_segment_bytes
end
