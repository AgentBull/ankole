defmodule BullX.AuthZ.ResourcePattern do
  @moduledoc """
  Resource-pattern validation and matching for AuthZ permission grants.

  A persisted pattern may contain zero or one `*`; that wildcard matches any
  character sequence, including `:`. Caller request resources are validated
  separately and must not contain wildcards.
  """

  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(pattern) when is_binary(pattern) do
    cond do
      pattern == "" -> {:error, "must not be empty"}
      wildcard_count(pattern) > 1 -> {:error, "must contain at most one '*'"}
      true -> :ok
    end
  end

  def validate(_pattern), do: {:error, "must be a string"}

  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, resource) when is_binary(pattern) and is_binary(resource) do
    case validate(pattern) do
      :ok -> do_match(pattern, resource)
      {:error, _reason} -> false
    end
  end

  def match?(_pattern, _resource), do: false

  defp do_match(pattern, resource) do
    case :binary.split(pattern, "*") do
      [^pattern] ->
        pattern == resource

      [prefix, suffix] ->
        String.starts_with?(resource, prefix) and String.ends_with?(resource, suffix) and
          byte_size(resource) >= byte_size(prefix) + byte_size(suffix)
    end
  end

  defp wildcard_count(pattern) do
    pattern
    |> :binary.matches("*")
    |> length()
  end
end
