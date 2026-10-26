defmodule Ankole.BackgroundAgentJobs.Trajectory do
  @moduledoc false

  @metadata_keys ~w(redacted content_truncated)

  @spec empty_header() :: map()
  def empty_header, do: %{"format" => "ankole_chatml", "version" => 1}

  @spec valid_header?(term()) :: boolean()
  def valid_header?(%{"format" => "ankole_chatml", "version" => 1} = value) do
    Map.keys(value) -- ~w(format version metadata) == [] and
      valid_metadata?(Map.get(value, "metadata"))
  end

  def valid_header?(_value), do: false

  defp valid_metadata?(nil), do: true

  defp valid_metadata?(metadata) when is_map(metadata) do
    Map.keys(metadata) -- @metadata_keys == [] and
      optional_boolean?(metadata, "redacted") and
      optional_boolean?(metadata, "content_truncated")
  end

  defp valid_metadata?(_metadata), do: false

  defp optional_boolean?(map, key),
    do: not Map.has_key?(map, key) or is_boolean(map[key])
end
