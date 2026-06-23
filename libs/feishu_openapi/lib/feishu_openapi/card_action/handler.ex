defmodule FeishuOpenAPI.CardAction.Handler do
  @moduledoc """
  Verifies, decodes, and dispatches Feishu/Lark interactive-card callbacks.

      handler =
        FeishuOpenAPI.CardAction.Handler.new(
          verification_token: "verification_token_xxx",
          encrypt_key: "encrypt_key_xxx",
          handler: fn action ->
            %{
              toast: %{
                type: "success",
                content: "handled"
              }
            }
          end
        )

      FeishuOpenAPI.CardAction.Handler.dispatch(handler, {:raw, raw_body, headers})

  Returns:

    * `{:ok, handler_result}` — handler ran, result passed through
    * `{:challenge, echo}` — URL-verification handshake
    * `{:error, reason}` — signature / decryption / JSON failure, or
      `{:handler_crashed, Exception.t()}` if the user handler raised
  """

  require Logger

  alias FeishuOpenAPI.CardAction

  @type callback_handler :: (CardAction.t() -> term())

  @type t :: %__MODULE__{
          verification_token: String.t() | nil,
          encrypt_key: String.t() | nil,
          skip_sign_verify: boolean(),
          handler: callback_handler() | nil
        }

  defstruct verification_token: nil,
            encrypt_key: nil,
            skip_sign_verify: false,
            handler: nil

  @new_opts [:verification_token, :encrypt_key, :skip_sign_verify, :handler]

  @spec new(keyword()) :: t()
  def new(opts) do
    opts = validate_new_opts!(opts)

    %__MODULE__{
      verification_token: opts[:verification_token],
      encrypt_key: opts[:encrypt_key],
      skip_sign_verify: Keyword.get(opts, :skip_sign_verify, false),
      handler: opts[:handler]
    }
  end

  @spec dispatch(t(), {:raw, binary(), map() | list()} | {:decoded, map()}) ::
          {:ok, term()} | {:challenge, String.t()} | {:error, term()}
  def dispatch(%__MODULE__{} = handler, {:raw, body, headers}) when is_binary(body) do
    handler
    |> CardAction.verify_and_decode(body, headers)
    |> route_result(handler)
  end

  def dispatch(%__MODULE__{} = handler, {:decoded, decoded}) when is_map(decoded) do
    handler
    |> CardAction.verify_decoded(decoded)
    |> route_result(handler)
  end

  defp route_result({:ok, %CardAction{} = action}, %__MODULE__{} = handler),
    do: invoke_handler(handler.handler, action)

  defp route_result({:challenge, _} = challenge, _handler), do: challenge
  defp route_result({:error, _} = err, _handler), do: err

  defp invoke_handler(nil, _action), do: {:error, :handler_not_configured}

  defp invoke_handler(handler, %CardAction{} = action) when is_function(handler, 1) do
    try do
      {:ok, handler.(action)}
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:feishu_openapi, :card_action, :handler_error],
          %{},
          %{type: action.type, reason: exception, kind: :error, stacktrace: stacktrace}
        )

        Logger.error(
          "feishu_openapi card action handler raised: " <>
            Exception.format(:error, exception, stacktrace)
        )

        {:error, {:handler_crashed, exception}}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:feishu_openapi, :card_action, :handler_error],
          %{},
          %{type: action.type, reason: reason, kind: kind, stacktrace: stacktrace}
        )

        Logger.error(
          "feishu_openapi card action handler threw: " <>
            Exception.format(kind, reason, stacktrace)
        )

        {:error, {:handler_crashed, {kind, reason}}}
    end
  end

  defp validate_new_opts!(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @new_opts)

    validate_optional_binary!(opts, :verification_token)
    validate_optional_binary!(opts, :encrypt_key)
    validate_boolean!(opts, :skip_sign_verify, false)
    validate_handler!(opts[:handler])

    opts
  end

  defp validate_new_opts!(_opts) do
    raise ArgumentError, "card action handler options must be a keyword list"
  end

  defp validate_optional_binary!(opts, key) do
    case opts[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        :ok

      value ->
        raise ArgumentError,
              "card action handler option #{inspect(key)} must be a string, got: #{inspect(value)}"
    end
  end

  defp validate_boolean!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    unless is_boolean(value) do
      raise ArgumentError,
            "card action handler option #{inspect(key)} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp validate_handler!(nil), do: :ok
  defp validate_handler!(handler) when is_function(handler, 1), do: :ok

  defp validate_handler!(handler) do
    raise ArgumentError,
          "card action handler option :handler must be a 1-arity function, got: #{inspect(handler)}"
  end
end
