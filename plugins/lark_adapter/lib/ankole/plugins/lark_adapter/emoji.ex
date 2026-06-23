defmodule Ankole.Plugins.LarkAdapter.Emoji do
  @moduledoc """
  Stable normalization for common Feishu/Lark emoji reaction keys.
  """

  @emoji %{
    "THUMBSUP" => "thumbs_up",
    "THUMBSDOWN" => "thumbs_down",
    "OK" => "ok",
    "HEART" => "heart",
    "LOVE" => "heart",
    "SMILE" => "smile",
    "LAUGH" => "laugh",
    "CLAP" => "clap",
    "FIRE" => "fire",
    "EYES" => "eyes",
    "DONE" => "check",
    "CHECK" => "check",
    "WRONG" => "cross",
    "CROSS" => "cross",
    "QUESTION" => "question",
    "EXCLAMATION" => "exclamation"
  }

  @reverse @emoji
           |> Enum.reverse()
           |> Map.new(fn {provider, normalized} -> {normalized, provider} end)

  @doc """
  Converts provider reaction names into Ankole's stable reaction vocabulary.
  """
  @spec normalize(term()) :: String.t()
  def normalize(value) when is_binary(value) do
    Map.get(@emoji, String.upcase(value), value)
  end

  def normalize(value), do: to_string(value)

  @doc """
  Converts a normalized reaction key back into the provider key used by Lark.
  """
  @spec provider_key(term()) :: String.t()
  def provider_key(value) when is_binary(value), do: Map.get(@reverse, value, value)
  def provider_key(value), do: to_string(value)
end
