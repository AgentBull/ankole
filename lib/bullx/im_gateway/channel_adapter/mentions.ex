defmodule BullX.IMGateway.ChannelAdapter.Mentions do
  @moduledoc """
  Normalizes provider-specific mention payloads for IM routing decisions.

  Channel adapters may supply structured ids, usernames, or only plain text.
  BullX reduces those forms to one mention shape so addressed-vs-ambient
  routing does not depend on a single provider's payload format.
  """

  import BullX.Utils.Map, only: [maybe_put: 3]

  @type mention :: %{
          optional(:id) => String.t(),
          optional(:username) => String.t(),
          optional(:source) => atom(),
          optional(:text) => String.t()
        }

  @callback parse_mentions(provider_message :: map(), source :: term()) :: [mention()]

  @spec bot_mentioned?([mention()], keyword()) :: boolean()
  def bot_mentioned?(mentions, opts) when is_list(mentions) and is_list(opts) do
    ids =
      opts
      |> Keyword.get(:ids, [])
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    usernames =
      opts
      |> Keyword.get(:usernames, [])
      |> Enum.map(&normalize_username/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.any?(mentions, fn mention ->
      mentioned_id = normalize_id(Map.get(mention, :id))
      mentioned_username = normalize_username(Map.get(mention, :username))

      (not is_nil(mentioned_id) and MapSet.member?(ids, mentioned_id)) or
        (not is_nil(mentioned_username) and MapSet.member?(usernames, mentioned_username))
    end)
  end

  @spec mention(keyword()) :: mention()
  def mention(opts) do
    %{}
    |> maybe_put(:id, normalize_id(Keyword.get(opts, :id)))
    |> maybe_put(:username, normalize_username(Keyword.get(opts, :username)))
    |> maybe_put(:source, Keyword.get(opts, :source))
    |> maybe_put(:text, normalize_text(Keyword.get(opts, :text)))
  end

  @spec extract_username_tokens(String.t()) :: [mention()]
  def extract_username_tokens(text) when is_binary(text) do
    ~r/(^|[^\p{L}\p{N}_])@(?<username>[A-Za-z0-9_]{5,32})(?=$|[^\p{L}\p{N}_])/u
    |> Regex.scan(text, capture: ["username"])
    |> Enum.map(fn [username] -> mention(username: username, source: :text) end)
  end

  def extract_username_tokens(_text), do: []

  @spec slice_text(String.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def slice_text(text, offset, length)
      when is_binary(text) and is_integer(offset) and is_integer(length) and offset >= 0 and
             length > 0 do
    String.slice(text, offset, length)
  end

  def slice_text(_text, _offset, _length), do: nil

  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value) and value != "", do: value
  defp normalize_id(_value), do: nil

  defp normalize_username(value) when is_binary(value) do
    value
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> nil
      username -> username
    end
  end

  defp normalize_username(_value), do: nil

  defp normalize_text(value) when is_binary(value) and value != "", do: value
  defp normalize_text(_value), do: nil
end
