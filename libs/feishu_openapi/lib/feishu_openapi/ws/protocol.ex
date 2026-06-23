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

  @fatal_handshake_codes [403, 514, 1_000_040_350]

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

  @spec config_from_map(map()) :: map()
  def config_from_map(map) when is_map(map) do
    %{}
    |> put_int(map, :ping_interval_s, ["PingInterval", "ping_interval"])
    |> put_int(map, :reconnect_interval_s, ["ReconnectInterval", "reconnect_interval"])
    |> put_int(map, :reconnect_nonce_s, ["ReconnectNonce", "reconnect_nonce"])
    |> put_int(map, :reconnect_count, ["ReconnectCount", "reconnect_count"])
  end

  def config_from_map(_), do: %{}

  @spec config_from_payload(binary()) :: {:ok, map()} | {:error, term()}
  def config_from_payload(payload) when is_binary(payload) and byte_size(payload) == 0,
    do: {:ok, %{}}

  def config_from_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- Torque.decode(payload) do
      {:ok, config_from_map(decoded)}
    end
  end

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

  @spec add_biz_rt([{String.t(), String.t()}], integer()) :: [{String.t(), String.t()}]
  def add_biz_rt(headers, duration_ms) when is_list(headers) and is_integer(duration_ms) do
    put_header(headers, @header_biz_rt, Integer.to_string(max(duration_ms, 0)))
  end

  @spec encode_ws_response({:ok, term()} | {:challenge, String.t()} | {:error, term()}) ::
          {:ok, binary()} | {:error, term()}
  def encode_ws_response(dispatch_result) do
    with {:ok, payload} <- response_map(dispatch_result),
         {:ok, encoded} <- Torque.encode(payload) do
      {:ok, encoded}
    end
  end

  @spec classify_handshake(integer() | nil, map() | list(), term()) :: {:fatal | :retry, term()}
  def classify_handshake(status, headers, fallback_reason) do
    handshake_status = header_int(headers, @header_handshake_status) || status
    handshake_msg = header(headers, @header_handshake_msg)
    auth_err_code = header_int(headers, @header_handshake_autherrcode)

    reason = {:handshake_error, handshake_status || status, handshake_msg || fallback_reason}

    cond do
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
    case Torque.encode(%{"challenge" => challenge}) do
      {:ok, data} ->
        {:ok, %{"code" => 200, "data" => Base.encode64(data)}}

      {:error, _} = err ->
        err
    end
  end

  defp response_map({:error, _reason}) do
    {:ok, %{"code" => 500}}
  end

  defp maybe_put_data(map, nil), do: map
  defp maybe_put_data(map, data) when is_binary(data), do: Map.put(map, "data", data)

  defp encode_response_data(result) when result in [nil, :ok, :no_handler, :unknown_event],
    do: nil

  defp encode_response_data(result) do
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
