defmodule FeishuOpenAPI.Event.Envelope do
  @moduledoc """
  Parses the outer wrapper of a Feishu/Lark event payload.

  Handles three shapes:
    * Encrypted envelope `{"encrypt": "<base64>"}` — decrypts with the configured
      key, then recurses into the plaintext.
    * P2 schema — `%{"schema" => "2.0", "header" => %{"event_type" => ...},
      "event" => ...}`.
    * P1 legacy — `%{"type" => "event_callback" | "url_verification",
      "event" => %{"type" => ...}, ...}`.

  Does not perform signature verification (that lives in
  `FeishuOpenAPI.Event.Dispatcher` so the timing-constant check can be disabled
  for tests).
  """

  @doc """
  Decode a webhook body. `body` is the raw JSON binary; `encrypt_key` is optional.

  Returns:
    * `{:ok, decoded_map}` — plaintext envelope ready to inspect
    * `{:error, reason}` — JSON / crypto failure
  """
  @spec decode(binary(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def decode(body, encrypt_key \\ nil) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"encrypt" => enc} when is_binary(encrypt_key) ->
          with {:ok, plain} <- FeishuOpenAPI.Crypto.decrypt(enc, encrypt_key),
               {:ok, inner} <- Jason.decode(plain) do
            {:ok, inner}
          end

        %{"encrypt" => _} ->
          {:error, :encrypt_key_required}

        _ ->
          {:ok, decoded}
      end
    end
  end

  @doc """
  Extracts the event-type string (the dispatch key) from a decoded envelope.

  Priority: P2 `header.event_type` > P1 `event.type` > top-level `type`.
  `nil` for envelopes we can't classify.
  """
  @spec event_type(map()) :: String.t() | nil
  def event_type(%{"schema" => "2.0", "header" => %{"event_type" => t}}) when is_binary(t), do: t

  def event_type(%{"type" => "event_callback", "event" => %{"type" => t}}) when is_binary(t),
    do: t

  def event_type(%{"type" => t}) when is_binary(t), do: t

  def event_type(%{"action" => action} = payload) when is_map(action) do
    case card_action_payload?(payload) do
      true -> "card.action.trigger"
      false -> nil
    end
  end

  def event_type(_), do: nil

  defp card_action_payload?(%{"open_message_id" => id}) when is_binary(id) and id != "",
    do: true

  defp card_action_payload?(%{"open_chat_id" => id}) when is_binary(id) and id != "",
    do: true

  defp card_action_payload?(_payload), do: false

  @doc "Extract the event payload (P2: `event`; P1: `event`)."
  @spec event(map()) :: map() | nil
  def event(%{"event" => e}) when is_map(e), do: e
  def event(_), do: nil

  @doc "Extract the verification token from either P1 or P2 envelopes."
  @spec token(map()) :: String.t() | nil
  def token(%{"schema" => "2.0", "header" => %{"token" => t}}) when is_binary(t), do: t
  def token(%{"token" => t}) when is_binary(t), do: t
  def token(_), do: nil

  @doc "Is this envelope a URL-verification challenge?"
  @spec challenge?(map()) :: boolean()
  def challenge?(%{"type" => "url_verification"}), do: true
  def challenge?(_), do: false

  @doc "Extract the challenge string (or `nil` if not a challenge)."
  @spec challenge(map()) :: String.t() | nil
  def challenge(%{"challenge" => c}) when is_binary(c), do: c
  def challenge(_), do: nil
end
