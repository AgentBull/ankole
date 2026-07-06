defmodule Ankole.PrincipalKey do
  @moduledoc """
  Canonical installation-wide Principal UID normalization.

  Principal UIDs are lowercase text keys shared by humans, agents, and
  principal-owned rows. This module owns that normalization outside Ecto so
  runtime boundaries can use the same rule as schemas.
  """

  @type normalize_result :: {:ok, String.t()} | {:error, :invalid_uid}

  @doc """
  Normalizes a required Principal UID.
  """
  @spec normalize(term()) :: normalize_result()
  def normalize(uid) when is_binary(uid) do
    case canonicalize(uid) do
      "" -> {:error, :invalid_uid}
      normalized -> {:ok, normalized}
    end
  end

  def normalize(_uid), do: {:error, :invalid_uid}

  @doc """
  Normalizes an optional Principal UID.
  """
  @spec normalize_optional(term()) :: {:ok, String.t() | nil} | {:error, :invalid_uid}
  def normalize_optional(nil), do: {:ok, nil}

  def normalize_optional(uid) when is_binary(uid) do
    case canonicalize(uid) do
      "" -> {:ok, nil}
      normalized -> {:ok, normalized}
    end
  end

  def normalize_optional(_uid), do: {:error, :invalid_uid}

  @spec canonicalize(String.t()) :: String.t()
  defp canonicalize(uid), do: uid |> String.trim() |> String.downcase()
end
