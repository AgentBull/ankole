defmodule Ankole.Plugins.Microsoft365Adapter.Emoji do
  @moduledoc false

  # Teams messageReaction reactionType values normalized into the shared
  # gateway emoji vocabulary. Unknown provider values pass through unchanged
  # so newer Teams reactions still round-trip as facts.
  @normalize %{
    "like" => "thumbs_up",
    "heart" => "heart",
    "laugh" => "laugh",
    "surprised" => "surprised",
    "sad" => "sad",
    "angry" => "angry"
  }

  @spec normalize(String.t()) :: String.t()
  def normalize(key) when is_binary(key) do
    Map.get(@normalize, String.downcase(key), key)
  end
end
