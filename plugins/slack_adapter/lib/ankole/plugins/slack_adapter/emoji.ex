defmodule Ankole.Plugins.SlackAdapter.Emoji do
  @moduledoc false

  @normalize %{
    "+1" => "thumbs_up",
    "thumbsup" => "thumbs_up",
    "-1" => "thumbs_down",
    "thumbsdown" => "thumbs_down",
    "ok_hand" => "ok",
    "heart" => "heart",
    "slightly_smiling_face" => "smile",
    "smile" => "smile",
    "laughing" => "laugh",
    "joy" => "laugh",
    "clap" => "clap",
    "fire" => "fire",
    "eyes" => "eyes",
    "white_check_mark" => "check",
    "heavy_check_mark" => "check",
    "x" => "cross",
    "question" => "question",
    "exclamation" => "exclamation",
    "heavy_exclamation_mark" => "exclamation"
  }

  @provider %{
    "thumbs_up" => "thumbsup",
    "thumbs_down" => "thumbsdown",
    "ok" => "ok_hand",
    "heart" => "heart",
    "smile" => "slightly_smiling_face",
    "laugh" => "laughing",
    "clap" => "clap",
    "fire" => "fire",
    "eyes" => "eyes",
    "check" => "white_check_mark",
    "cross" => "x",
    "question" => "question",
    "exclamation" => "exclamation"
  }

  @spec normalize(String.t()) :: String.t()
  def normalize(key) when is_binary(key) do
    key = String.replace(key, ~r/::skin-tone-\d+$/, "")
    Map.get(@normalize, key, key)
  end

  @spec provider_key(String.t()) :: String.t()
  def provider_key(key), do: Map.get(@provider, key, key)
end
