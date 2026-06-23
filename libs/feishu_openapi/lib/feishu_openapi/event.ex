defmodule FeishuOpenAPI.Event do
  @moduledoc """
  Normalized event struct returned by `verify_and_decode/3` and passed to
  handlers registered via `FeishuOpenAPI.Event.Dispatcher.on/3`.

  The original decoded envelope map is always available on the `:raw` field
  for callers that need P1/P2-specific payload details the struct does not
  surface directly.
  """

  alias FeishuOpenAPI.Crypto
  alias FeishuOpenAPI.Event.Envelope

  @default_max_skew_seconds 300

  @enforce_keys [:raw]
  defstruct [
    :id,
    :type,
    :content,
    :created_at,
    :tenant_key,
    :app_id,
    :schema,
    :raw
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: String.t() | nil,
          content: map() | nil,
          created_at: DateTime.t() | nil,
          tenant_key: String.t() | nil,
          app_id: String.t() | nil,
          schema: String.t() | nil,
          raw: map()
        }

  @typedoc """
  Accepted by `verify_and_decode/3`. Any struct / map that carries these keys
  works — typically a `FeishuOpenAPI.Event.Dispatcher.t()`.
  """
  @type verify_config :: %{
          optional(:verification_token) => String.t() | nil,
          optional(:encrypt_key) => String.t() | nil,
          optional(:skip_sign_verify) => boolean(),
          optional(:skip_timestamp_check) => boolean(),
          optional(:max_skew_seconds) => non_neg_integer()
        }

  @doc """
  Verify and decode a raw webhook body. Returns:

    * `{:ok, %Event{}}` — successfully decoded + verified
    * `{:challenge, echo}` — URL-verification handshake
    * `{:error, reason}` — signature / decryption / JSON / replay failure

  Steps, in order:

  1. JSON decode + (if encrypted) decrypt with `encrypt_key`
  2. Verify `x-lark-signature` (unless `skip_sign_verify` or `encrypt_key` is nil)
  3. Verify `x-lark-request-timestamp` within `max_skew_seconds`
     (unless `skip_timestamp_check` or `encrypt_key` is nil)
  4. Verify `verification_token` against the envelope's token (unless nil)
  """
  @spec verify_and_decode(verify_config() | struct(), binary(), map() | list()) ::
          {:ok, t()} | {:challenge, String.t()} | {:error, term()}
  def verify_and_decode(config, body, headers) when is_binary(body) do
    cfg = normalize_config(config)

    with {:ok, decoded} <- Envelope.decode(body, cfg.encrypt_key),
         :ok <- verify_signature(cfg, body, headers, decoded),
         :ok <- verify_timestamp(cfg, headers, decoded),
         :ok <- verify_token(cfg, decoded) do
      if Envelope.challenge?(decoded) do
        {:challenge, Envelope.challenge(decoded)}
      else
        {:ok, from_envelope(decoded)}
      end
    end
  end

  @doc """
  Verify an already-decoded envelope. Used by transports that receive a
  parsed map, skipping body-level crypto.

  Still runs verification_token check, then returns either a challenge or
  a normalized `%Event{}`.
  """
  @spec verify_decoded(verify_config() | struct(), map()) ::
          {:ok, t()} | {:challenge, String.t()} | {:error, term()}
  def verify_decoded(config, decoded) when is_map(decoded) do
    cfg = normalize_config(config)

    with :ok <- verify_token(cfg, decoded) do
      decoded_result(decoded)
    end
  end

  @doc """
  Verify a decoded envelope from an already-authenticated transport.

  Long-connection WebSocket event push authenticates when the connection is
  established. Subsequent event frames do not need the webhook Verification
  Token check.
  """
  @spec verify_trusted_decoded(verify_config() | struct(), map()) ::
          {:ok, t()} | {:challenge, String.t()} | {:error, term()}
  def verify_trusted_decoded(_config, decoded) when is_map(decoded), do: decoded_result(decoded)

  @doc """
  Convert a decoded envelope map into a normalized `%Event{}`.

  Handles both P2 (`schema: "2.0"`) and P1 (`type: "event_callback"`)
  shapes, plus generic fallback. Unknown envelopes yield a struct with
  only `:raw` and best-effort `:type`.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{"schema" => "2.0", "header" => header} = envelope)
      when is_map(header) do
    %__MODULE__{
      id: Map.get(header, "event_id"),
      type: Map.get(header, "event_type"),
      content: Map.get(envelope, "event"),
      created_at: parse_created_at(Map.get(header, "create_time")),
      tenant_key: Map.get(header, "tenant_key"),
      app_id: Map.get(header, "app_id"),
      schema: "2.0",
      raw: envelope
    }
  end

  def from_envelope(
        %{"type" => "event_callback", "event" => %{"type" => type} = event} = envelope
      )
      when is_map(event) do
    %__MODULE__{
      id: Map.get(envelope, "uuid"),
      type: type,
      content: event,
      created_at: parse_created_at(Map.get(event, "create_time") || Map.get(envelope, "ts")),
      tenant_key: Map.get(envelope, "tenant_key"),
      app_id: Map.get(envelope, "app_id"),
      schema: "1.0",
      raw: envelope
    }
  end

  def from_envelope(envelope) when is_map(envelope) do
    %__MODULE__{
      type: Envelope.event_type(envelope),
      content: Map.get(envelope, "event"),
      raw: envelope
    }
  end

  # --- verification helpers ------------------------------------------------

  defp normalize_config(%_{} = struct), do: normalize_config(Map.from_struct(struct))

  defp normalize_config(map) when is_map(map) do
    %{
      verification_token: Map.get(map, :verification_token),
      encrypt_key: Map.get(map, :encrypt_key),
      skip_sign_verify: Map.get(map, :skip_sign_verify, false),
      skip_timestamp_check: Map.get(map, :skip_timestamp_check, false),
      max_skew_seconds: Map.get(map, :max_skew_seconds, @default_max_skew_seconds)
    }
  end

  defp verify_signature(%{skip_sign_verify: true}, _body, _headers, _decoded), do: :ok
  defp verify_signature(%{encrypt_key: nil}, _body, _headers, _decoded), do: :ok

  defp verify_signature(%{encrypt_key: key}, body, headers, decoded) do
    ts = header(headers, "x-lark-request-timestamp")
    nonce = header(headers, "x-lark-request-nonce")
    signature = header(headers, "x-lark-signature")

    cond do
      is_nil(ts) or is_nil(nonce) or is_nil(signature) ->
        if Envelope.challenge?(decoded), do: :ok, else: {:error, :missing_signature_headers}

      true ->
        Crypto.verify_event(ts, nonce, key, body, signature)
    end
  end

  defp verify_timestamp(%{skip_sign_verify: true}, _headers, _decoded), do: :ok
  defp verify_timestamp(%{skip_timestamp_check: true}, _headers, _decoded), do: :ok
  defp verify_timestamp(%{encrypt_key: nil}, _headers, _decoded), do: :ok

  defp verify_timestamp(%{max_skew_seconds: max_skew}, headers, decoded) do
    ts = header(headers, "x-lark-request-timestamp")

    cond do
      is_nil(ts) ->
        if Envelope.challenge?(decoded), do: :ok, else: {:error, :missing_signature_headers}

      true ->
        check_timestamp_skew(ts, max_skew)
    end
  end

  defp verify_token(%{verification_token: nil}, _decoded), do: :ok

  defp verify_token(%{verification_token: vt}, decoded) do
    if Envelope.token(decoded) == vt, do: :ok, else: {:error, :bad_verification_token}
  end

  defp decoded_result(decoded) do
    if Envelope.challenge?(decoded) do
      {:challenge, Envelope.challenge(decoded)}
    else
      {:ok, from_envelope(decoded)}
    end
  end

  defp check_timestamp_skew(ts_binary, max_skew_seconds) do
    case Integer.parse(ts_binary) do
      {ts_seconds, _} ->
        now = System.system_time(:second)

        if abs(now - ts_seconds) <= max_skew_seconds,
          do: :ok,
          else: {:error, :timestamp_skew}

      _ ->
        {:error, :bad_timestamp}
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

  defp parse_created_at(nil), do: nil

  defp parse_created_at(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {int, _} -> unix_to_datetime(int)
      :error -> nil
    end
  end

  defp parse_created_at(ts) when is_integer(ts), do: unix_to_datetime(ts)
  defp parse_created_at(_), do: nil

  defp unix_to_datetime(int) do
    # Feishu timestamps come in either seconds or milliseconds. P2 headers use
    # milliseconds; P1 `ts` is typically seconds with a decimal fractional part
    # (we've already stripped that via Integer.parse). Treat anything past the
    # year 3000 in seconds (~3.2e10) as milliseconds.
    unit = if int >= 10_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(int, unit) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end
end
