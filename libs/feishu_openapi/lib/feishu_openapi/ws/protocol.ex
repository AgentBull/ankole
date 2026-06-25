defmodule FeishuOpenAPI.WS.Protocol do
  @moduledoc """
  Helpers for Feishu's websocket event protocol.

  This module centralizes wire-level quirks that are easy to scatter across the
  websocket client: handshake failure classification, config extraction from
  server payloads, response envelope encoding, and the special headers Feishu
  uses for business-RT and auth errors. It exists so `FeishuOpenAPI.WS.Client`
  can stay focused on connection lifecycle instead of packet details.
  """

  @header_biz_rt "biz_rt"
  @header_handshake_status "handshake-status"
  @header_handshake_msg "handshake-msg"
  @header_handshake_autherrcode "handshake-autherrcode"

  # Provider codes that mean the connection will never succeed as configured:
  # 403 (forbidden), 514, and 1_000_040_350 (bad app credentials). Retrying these
  # just hammers the endpoint, so they are treated as fatal and stop the client.
  @fatal_handshake_codes [403, 514, 1_000_040_350]

  @doc """
  Parse the `service_id` query param Feishu embeds in the WS URL.

  Frames echo this id back to the provider, so we extract it once at connect
  time. Defaults to `0` for any malformed or missing value.
  """
  @spec service_id_from_url(String.t()) :: integer()
  def service_id_from_url(url) when is_binary(url) do
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    case Integer.parse(Map.get(params, "service_id", "0")) do
      {n, _} -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end

  def service_id_from_url(_), do: 0

  @doc """
  Pull connection-tuning knobs out of a server config map into our atom-keyed
  shape, ignoring keys we don't recognize.

  Each setting accepts two spellings because the endpoint-discovery response and
  the in-band `pong` payload disagree on casing (e.g. `PingInterval` vs
  `ping_interval`). Absent keys are simply left out so the client keeps its
  current/default value.
  """
  @spec config_from_map(map()) :: map()
  def config_from_map(map) when is_map(map) do
    %{}
    |> put_int(map, :ping_interval_s, ["PingInterval", "ping_interval"])
    |> put_int(map, :reconnect_interval_s, ["ReconnectInterval", "reconnect_interval"])
    |> put_int(map, :reconnect_nonce_s, ["ReconnectNonce", "reconnect_nonce"])
    |> put_int(map, :reconnect_count, ["ReconnectCount", "reconnect_count"])
  end

  def config_from_map(_), do: %{}

  @doc """
  Decode a `pong` frame payload into a config map. The provider can revise ping
  interval and reconnect parameters at runtime by attaching JSON to a pong.
  """
  @spec config_from_payload(binary()) :: {:ok, map()} | {:error, term()}
  # Empty pong payload is the common case (a bare heartbeat ack), so short-circuit
  # before attempting a JSON decode.
  def config_from_payload(payload) when is_binary(payload) and byte_size(payload) == 0,
    do: {:ok, %{}}

  def config_from_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- Torque.decode(payload) do
      {:ok, config_from_map(decoded)}
    end
  end

  @doc """
  Upsert a header by key, replacing any existing entry and appending at the end.

  Re-appending (rather than updating in place) keeps the provider's expected
  header ordering, with our added headers last.
  """
  @spec put_header([{String.t(), String.t()}], String.t(), String.t()) :: [
          {String.t(), String.t()}
        ]
  def put_header(headers, key, value)
      when is_list(headers) and is_binary(key) and is_binary(value) do
    Enum.reject(headers, fn
      {^key, _} -> true
      _ -> false
    end) ++ [{key, value}]
  end

  @doc """
  Stamp the `biz_rt` (business response time) header on a response frame.

  Feishu reads this back as the handler's processing time in milliseconds for
  its own latency monitoring. Clamped to non-negative to guard against clock
  jitter producing a negative duration.
  """
  @spec add_biz_rt([{String.t(), String.t()}], integer()) :: [{String.t(), String.t()}]
  def add_biz_rt(headers, duration_ms) when is_list(headers) and is_integer(duration_ms) do
    put_header(headers, @header_biz_rt, Integer.to_string(max(duration_ms, 0)))
  end

  @doc """
  Build the JSON payload Feishu expects in the ack frame for an event/card.

  Maps a dispatcher result to the provider's `{code, data}` envelope: success →
  200, a URL-verification challenge → 200 with the echo, any error → 500. See
  `response_map/1` for how each shape is rendered.
  """
  @spec encode_ws_response({:ok, term()} | {:challenge, String.t()} | {:error, term()}) ::
          {:ok, binary()} | {:error, term()}
  def encode_ws_response(dispatch_result) do
    with {:ok, payload} <- response_map(dispatch_result),
         {:ok, encoded} <- Torque.encode(payload) do
      {:ok, encoded}
    end
  end

  @doc """
  Decide whether a failed WS upgrade is permanent (`:fatal`) or worth retrying
  (`:retry`).

  Mint's generic upgrade error rarely says *why* the provider refused, so we
  prefer Feishu's own `handshake-*` headers when present. The 514 + auth-error
  pairing and the bare fatal codes mean a misconfigured app (wrong
  credentials/permissions): retrying would loop forever, so we stop. Anything
  else is assumed transient and reconnect is scheduled.
  """
  @spec classify_handshake(integer() | nil, map() | list(), term()) :: {:fatal | :retry, term()}
  def classify_handshake(status, headers, fallback_reason) do
    # Feishu's own handshake-status header is authoritative; fall back to the raw
    # HTTP status only when it's absent.
    handshake_status = header_int(headers, @header_handshake_status) || status
    handshake_msg = header(headers, @header_handshake_msg)
    auth_err_code = header_int(headers, @header_handshake_autherrcode)

    reason = {:handshake_error, handshake_status || status, handshake_msg || fallback_reason}

    cond do
      # Spells out the canonical "bad credentials" signal (514 + auth-error code)
      # for clarity; note 514 is already in @fatal_handshake_codes below, so any
      # 514 is fatal regardless of the auth-error code.
      handshake_status == 514 and auth_err_code == 1_000_040_350 ->
        {:fatal, reason}

      handshake_status in @fatal_handshake_codes ->
        {:fatal, reason}

      true ->
        {:retry, reason}
    end
  end

  defp response_map({:ok, result}) do
    {:ok, maybe_put_data(%{"code" => 200}, encode_response_data(result))}
  end

  defp response_map({:challenge, challenge}) do
    # The WS `data` field carries a base64'd JSON blob, so even the challenge echo
    # is double-encoded: JSON-encode `{"challenge": ...}`, then base64 it.
    case Torque.encode(%{"challenge" => challenge}) do
      {:ok, data} ->
        {:ok, %{"code" => 200, "data" => Base.encode64(data)}}

      {:error, _} = err ->
        err
    end
  end

  defp response_map({:error, _reason}) do
    # Provider only inspects the code for non-2xx; no body needed.
    {:ok, %{"code" => 500}}
  end

  defp maybe_put_data(map, nil), do: map
  defp maybe_put_data(map, data) when is_binary(data), do: Map.put(map, "data", data)

  # Acks that carry no meaningful return value omit `data` entirely; the bare
  # `{"code": 200}` is enough to satisfy the provider.
  defp encode_response_data(result) when result in [nil, :ok, :no_handler, :unknown_event],
    do: nil

  defp encode_response_data(result) do
    # `data` is base64'd JSON (see the challenge case). On encode failure we drop
    # the body rather than fail the whole ack — a 200 with no data still acks.
    case Torque.encode(result) do
      {:ok, encoded} -> Base.encode64(encoded)
      {:error, _} -> nil
    end
  end

  defp put_int(acc, map, key, candidates) do
    case fetch_int(map, candidates) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp fetch_int(map, [candidate | rest]) do
    case Map.fetch(map, candidate) do
      {:ok, value} ->
        parse_int(value)

      :error ->
        fetch_int(map, rest)
    end
  end

  defp fetch_int(_map, []), do: :error

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  # Case-insensitive header lookup over either a map or a `[{k, v}]` list, since
  # the upgrade-response headers reach us in different shapes. `target` is assumed
  # already-lowercase.
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

  defp header(_headers, _target), do: nil

  defp header_int(headers, target) do
    case header(headers, target) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp normalize_header_value([value | _]), do: normalize_header_value(value)
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_header_value(_), do: nil
end
