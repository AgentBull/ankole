defmodule FeishuOpenAPI.CardAction do
  @moduledoc """
  Normalized interactive-card action callback payload.

  This is the HTTP callback shape used by Feishu/Lark interactive cards. It is
  distinct from event-subscription webhooks:

    * encrypted bodies still use the shared `Encrypt Key`
    * `url_verification` still uses the top-level `challenge`
    * request signing uses SHA1 over `timestamp || nonce || verification_token || raw_body`

  `verify_and_decode/3` matches the official Go SDK behavior closely enough for
  the same card-action scenarios to work in this client.
  """

  alias FeishuOpenAPI.{Crypto, Event.Envelope}

  @enforce_keys [:raw]
  defstruct [
    :open_id,
    :user_id,
    :open_message_id,
    :open_chat_id,
    :tenant_key,
    :token,
    :timezone,
    :challenge,
    :type,
    :action,
    :raw
  ]

  @type t :: %__MODULE__{
          open_id: String.t() | nil,
          user_id: String.t() | nil,
          open_message_id: String.t() | nil,
          open_chat_id: String.t() | nil,
          tenant_key: String.t() | nil,
          token: String.t() | nil,
          timezone: String.t() | nil,
          challenge: String.t() | nil,
          type: String.t() | nil,
          action: map() | nil,
          raw: map()
        }

  @typedoc """
  Accepted by `verify_and_decode/3`. Any struct / map that carries these keys
  works — typically a `FeishuOpenAPI.CardAction.Handler.t()`.
  """
  @type verify_config :: %{
          optional(:verification_token) => String.t() | nil,
          optional(:encrypt_key) => String.t() | nil,
          optional(:skip_sign_verify) => boolean()
        }

  @doc """
  Verify and decode a raw interactive-card callback body.

  Returns:

    * `{:ok, %CardAction{}}` — successfully decoded and verified
    * `{:challenge, echo}` — URL-verification handshake
    * `{:error, reason}` — signature / decryption / JSON / token failure
  """
  @spec verify_and_decode(verify_config() | struct(), binary(), map() | list()) ::
          {:ok, t()} | {:challenge, String.t()} | {:error, term()}
  def verify_and_decode(config, body, headers) when is_binary(body) do
    cfg = normalize_config(config)

    with {:ok, decoded} <- Envelope.decode(body, cfg.encrypt_key),
         :ok <- verify_challenge_token(cfg, decoded),
         :ok <- verify_signature(cfg, body, headers, decoded) do
      if challenge?(decoded) do
        {:challenge, challenge(decoded)}
      else
        {:ok, from_payload(decoded)}
      end
    end
  end

  @doc """
  Verify an already-decoded card-action payload.

  This skips body-level signature verification because the raw body is no longer
  available, but still enforces challenge-token validation when configured.
  """
  @spec verify_decoded(verify_config() | struct(), map()) ::
          {:ok, t()} | {:challenge, String.t()} | {:error, term()}
  def verify_decoded(config, decoded) when is_map(decoded) do
    cfg = normalize_config(config)

    with :ok <- verify_challenge_token(cfg, decoded) do
      if challenge?(decoded) do
        {:challenge, challenge(decoded)}
      else
        {:ok, from_payload(decoded)}
      end
    end
  end

  @doc """
  Convert a decoded card-action payload into `%CardAction{}`.
  """
  @spec from_payload(map()) :: t()
  def from_payload(payload) when is_map(payload) do
    %__MODULE__{
      open_id: Map.get(payload, "open_id"),
      user_id: Map.get(payload, "user_id"),
      open_message_id: Map.get(payload, "open_message_id"),
      open_chat_id: Map.get(payload, "open_chat_id"),
      tenant_key: Map.get(payload, "tenant_key"),
      token: Map.get(payload, "token"),
      timezone: Map.get(payload, "timezone"),
      challenge: Map.get(payload, "challenge"),
      type: Map.get(payload, "type"),
      action: map_or_nil(Map.get(payload, "action")),
      raw: payload
    }
  end

  @doc "Is this payload a card `url_verification` challenge?"
  @spec challenge?(map()) :: boolean()
  def challenge?(%{"type" => "url_verification"}), do: true
  def challenge?(_), do: false

  @doc "Extract the challenge string from a decoded payload."
  @spec challenge(map()) :: String.t() | nil
  def challenge(%{"challenge" => challenge}) when is_binary(challenge), do: challenge
  def challenge(_), do: nil

  # --- verification helpers ----------------------------------------------

  defp normalize_config(%_{} = struct), do: normalize_config(Map.from_struct(struct))

  defp normalize_config(map) when is_map(map) do
    %{
      verification_token: Map.get(map, :verification_token),
      encrypt_key: Map.get(map, :encrypt_key),
      skip_sign_verify: Map.get(map, :skip_sign_verify, false)
    }
  end

  defp verify_challenge_token(%{verification_token: nil}, _decoded), do: :ok

  defp verify_challenge_token(%{verification_token: token}, decoded) do
    if challenge?(decoded) do
      if Map.get(decoded, "token") == token, do: :ok, else: {:error, :bad_verification_token}
    else
      :ok
    end
  end

  defp verify_signature(%{skip_sign_verify: true}, _body, _headers, _decoded), do: :ok
  defp verify_signature(%{verification_token: nil}, _body, _headers, _decoded), do: :ok

  defp verify_signature(%{verification_token: token}, body, headers, decoded) do
    if challenge?(decoded) do
      :ok
    else
      ts = header(headers, "x-lark-request-timestamp")
      nonce = header(headers, "x-lark-request-nonce")
      signature = header(headers, "x-lark-signature")

      cond do
        is_nil(ts) or is_nil(nonce) or is_nil(signature) ->
          {:error, :missing_signature_headers}

        true ->
          Crypto.verify_card(ts, nonce, token, body, signature)
      end
    end
  end

  defp header(headers, target) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == target, do: normalize_header_value(v)
    end)
  end

  defp header(headers, target) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) or is_atom(k) ->
        if String.downcase(to_string(k)) == target, do: normalize_header_value(v)

      _ ->
        nil
    end)
  end

  defp normalize_header_value([v | _]), do: v
  defp normalize_header_value(v) when is_binary(v), do: v
  defp normalize_header_value(_), do: nil

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil
end
