defmodule FeishuOpenAPI.Event.Dispatcher do
  @moduledoc """
  Routes decoded Feishu/Lark events to user-registered handler functions.

      dispatcher =
        FeishuOpenAPI.Event.Dispatcher.new(
          verification_token: "v_xxx",
          encrypt_key: "e_xxx",
          client: client          # auto-registers the `app_ticket` handler for
                                  # marketplace apps, writing to TokenManager
        )
        |> FeishuOpenAPI.Event.Dispatcher.on("im.message.receive_v1", &MyBot.on_msg/2)

      FeishuOpenAPI.Event.Dispatcher.dispatch(dispatcher, {:raw, raw_body, headers})

  Returns:
    * `{:ok, handler_result}` — handler ran successfully; `{:ok, _}` handler
      returns are normalized to `:ok`
    * `{:ok, :no_handler}` — known event but nothing registered
    * `{:challenge, echo}` — URL-verification handshake; caller must respond
      `%{"challenge" => echo}` to Feishu
    * `{:error, reason}` — signature / decryption / JSON failure,
      `{:handler_failed, reason}` when a user handler returned `{:error, reason}`,
      or `{:handler_crashed, Exception.t()}` if a user handler raised

  Two input shapes:
    * `{:raw, body, headers}` — HTTP webhook. Verifies signature (unless
      `skip_sign_verify: true` or `encrypt_key` is nil) and replay-window
      (unless `skip_timestamp_check: true`).
    * `{:decoded, map}` — already-parsed envelope. Raw body signature checks
      are skipped, but `verification_token` is still enforced when configured.
    * `{:trusted_decoded, map}` — decoded envelope from an already-authenticated
      transport such as long-connection WebSocket. Skips webhook Verification
      Token checks.

  Handler functions receive `(event_type_string, %FeishuOpenAPI.Event{})`.
  The full raw envelope is always accessible as `event.raw`. Callback
  handler return values are forwarded back to the caller so they can be
  serialized into the transport response. For real interactive-card HTTP
  callbacks, use `FeishuOpenAPI.CardAction.Handler`.

  ## Replay protection

  When `encrypt_key` is configured, the dispatcher checks that
  `x-lark-request-timestamp` is within `max_skew_seconds` (default 300s) of
  wall-clock time. Rejects with `{:error, :timestamp_skew}`. This is on top
  of signature verification — an attacker replaying a captured-valid webhook
  past the window will be rejected even with a valid signature.
  """

  require Logger

  alias FeishuOpenAPI.{Client, Event, TokenManager}

  @default_max_skew_seconds 300

  @type handler :: (String.t(), Event.t() -> term())

  @type t :: %__MODULE__{
          verification_token: String.t() | nil,
          encrypt_key: String.t() | nil,
          client: Client.t() | nil,
          handlers: %{optional(String.t()) => handler()},
          callback_handlers: %{optional(String.t()) => handler()},
          skip_sign_verify: boolean(),
          skip_timestamp_check: boolean(),
          max_skew_seconds: non_neg_integer()
        }

  defstruct verification_token: nil,
            encrypt_key: nil,
            client: nil,
            handlers: %{},
            callback_handlers: %{},
            skip_sign_verify: false,
            skip_timestamp_check: false,
            max_skew_seconds: @default_max_skew_seconds

  @new_opts [
    :verification_token,
    :encrypt_key,
    :client,
    :skip_sign_verify,
    :skip_timestamp_check,
    :max_skew_seconds
  ]

  @spec new(keyword()) :: t()
  @doc """
  Builds a dispatcher and optionally wires marketplace app_ticket handling.
  """
  def new(opts \\ []) do
    opts = validate_new_opts!(opts)

    dispatcher = %__MODULE__{
      verification_token: opts[:verification_token],
      encrypt_key: opts[:encrypt_key],
      client: opts[:client],
      skip_sign_verify: Keyword.get(opts, :skip_sign_verify, false),
      skip_timestamp_check: Keyword.get(opts, :skip_timestamp_check, false),
      max_skew_seconds: Keyword.get(opts, :max_skew_seconds, @default_max_skew_seconds)
    }

    maybe_register_app_ticket_handler(dispatcher)
  end

  @doc """
  Registers a normal event handler by Feishu event type.
  """
  @spec on(t(), String.t(), handler()) :: t()
  def on(%__MODULE__{} = d, event_type, handler)
      when is_binary(event_type) and is_function(handler, 2) do
    %{d | handlers: Map.put(d.handlers, event_type, handler)}
  end

  @doc """
  Registers an interactive callback handler by callback type.
  """
  @spec on_callback(t(), String.t(), handler()) :: t()
  def on_callback(%__MODULE__{} = d, callback_type, handler)
      when is_binary(callback_type) and is_function(handler, 2) do
    %{d | callback_handlers: Map.put(d.callback_handlers, callback_type, handler)}
  end

  @doc """
  Verifies, decodes, and routes an event from an HTTP or trusted WS transport.
  """
  @spec dispatch(
          t(),
          {:raw, binary(), map() | list()} | {:decoded, map()} | {:trusted_decoded, map()}
        ) ::
          {:ok, term()} | {:challenge, String.t()} | {:error, term()}
  def dispatch(%__MODULE__{} = d, {:raw, body, headers}) when is_binary(body) do
    d
    |> Event.verify_and_decode(body, headers)
    |> route_result(d)
  end

  def dispatch(%__MODULE__{} = d, {:decoded, decoded}) when is_map(decoded) do
    d
    |> Event.verify_decoded(decoded)
    |> route_result(d)
  end

  def dispatch(%__MODULE__{} = d, {:trusted_decoded, decoded}) when is_map(decoded) do
    d
    |> Event.verify_trusted_decoded(decoded)
    |> route_result(d)
  end

  # --- internals -----------------------------------------------------------

  # verify_*/2 already separated the outcomes; forward challenge/error untouched
  # and only routing a verified event needs handler lookup.
  defp route_result({:ok, %Event{} = event}, %__MODULE__{} = d), do: route(d, event)
  defp route_result({:challenge, _} = challenge, _d), do: challenge
  defp route_result({:error, _} = err, _d), do: err

  # No type means we couldn't classify the envelope — distinct from "classified but
  # no handler registered" so callers can tell the two apart.
  defp route(_d, %Event{type: nil}), do: {:ok, :unknown_event}

  defp route(%__MODULE__{} = d, %Event{type: event_type} = event) do
    # Normal event handlers take precedence over callback handlers; both are keyed
    # by event type. A type with neither registered is an explicit no_handler ack.
    cond do
      handler = Map.get(d.handlers, event_type) ->
        invoke_handler(handler, event_type, event)

      handler = Map.get(d.callback_handlers, event_type) ->
        invoke_handler(handler, event_type, event)

      true ->
        {:ok, :no_handler}
    end
  end

  defp invoke_handler(handler, event_type, %Event{} = event) do
    try do
      handler.(event_type, event)
      |> handler_result()
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        # Handler failures are returned as data because webhook callers must send
        # a controlled response instead of crashing the Phoenix/Cowboy process.
        :telemetry.execute(
          [:feishu_openapi, :event, :handler_error],
          %{},
          %{event_type: event_type, kind: :error, reason: exception, stacktrace: stacktrace}
        )

        Logger.error(
          "feishu_openapi event handler for #{event_type} raised: " <>
            Exception.format(:error, exception, stacktrace)
        )

        {:error, {:handler_crashed, exception}}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:feishu_openapi, :event, :handler_error],
          %{},
          %{event_type: event_type, kind: kind, reason: reason, stacktrace: stacktrace}
        )

        Logger.error(
          "feishu_openapi event handler for #{event_type} threw: " <>
            Exception.format(kind, reason, stacktrace)
        )

        {:error, {:handler_crashed, {kind, reason}}}
    end
  end

  # Normalize a handler's return so the transport can serialize it consistently:
  #   {:error, _}    → tagged handler_failed (becomes a 500-class ack)
  #   {:ok, _}       → collapsed to :ok (the inner value isn't part of the contract)
  #   anything else  → passed through as the response body (e.g. a card update map)
  defp handler_result({:error, reason}), do: {:error, {:handler_failed, reason}}
  defp handler_result({:ok, _result}), do: {:ok, :ok}
  defp handler_result(result), do: {:ok, result}

  defp maybe_register_app_ticket_handler(%__MODULE__{client: nil} = d), do: d

  defp maybe_register_app_ticket_handler(%__MODULE__{client: %Client{} = client} = d) do
    # Marketplace apps receive app_ticket through events, but token fetching needs
    # it later. Auto-registration keeps the common path one configuration option.
    on(d, "app_ticket", fn _event_type, %Event{} = event ->
      case extract_app_ticket(event) do
        {:ok, ticket} ->
          TokenManager.put_app_ticket(client, ticket)
          :ok

        :error ->
          Logger.warning("feishu_openapi received app_ticket event without a ticket field")
          :ok
      end
    end)
  end

  # The ticket lives under `event` in P2 but at the top level in some P1 shapes,
  # so check the normalized content first, then fall back to the raw envelope.
  defp extract_app_ticket(%Event{content: content, raw: raw}) do
    with :error <- fetch_string(content || %{}, "app_ticket"),
         :error <- fetch_string(raw, "app_ticket") do
      :error
    else
      {:ok, _} = ok -> ok
    end
  end

  defp fetch_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_binary(v) -> {:ok, v}
      _ -> :error
    end
  end

  defp fetch_string(_map, _key), do: :error

  defp validate_new_opts!(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @new_opts)

    validate_optional_binary!(opts, :verification_token)
    validate_optional_binary!(opts, :encrypt_key)
    validate_optional_client!(opts[:client])
    validate_boolean!(opts, :skip_sign_verify, false)
    validate_boolean!(opts, :skip_timestamp_check, false)
    validate_non_neg_integer!(opts, :max_skew_seconds, @default_max_skew_seconds)

    opts
  end

  defp validate_new_opts!(_opts) do
    raise ArgumentError, "dispatcher options must be a keyword list"
  end

  defp validate_optional_binary!(opts, key) do
    case opts[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        :ok

      value ->
        raise ArgumentError,
              "dispatcher option #{inspect(key)} must be a string, got: #{inspect(value)}"
    end
  end

  defp validate_optional_client!(nil), do: :ok
  defp validate_optional_client!(%Client{}), do: :ok

  defp validate_optional_client!(value) do
    raise ArgumentError,
          "dispatcher option :client must be a FeishuOpenAPI.Client struct, got: #{inspect(value)}"
  end

  defp validate_boolean!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    unless is_boolean(value) do
      raise ArgumentError, "dispatcher option #{inspect(key)} must be a boolean"
    end
  end

  defp validate_non_neg_integer!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    unless is_integer(value) and value >= 0 do
      raise ArgumentError, "dispatcher option #{inspect(key)} must be a non-negative integer"
    end
  end
end
