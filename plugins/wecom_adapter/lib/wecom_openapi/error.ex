defmodule WeComOpenAPI.Error do
  @moduledoc """
  Represents a failed WeCom API call, transport failure, or bot channel error.

  Corp REST responses fail as HTTP 200 + `{"errcode" => <integer>, "errmsg" =>
  "..."}` where a non-zero `errcode` is the failure. Bot WebSocket acks carry
  the same `errcode`/`errmsg` pair in the ack frame.

  `:reason` folds the codes into a stable classification atom the adapter can
  branch on (`:auth`, `:ip_rejected`, `:rate_limited`, `:invalid_code`,
  `:not_found`, `:transport`, `:unexpected_shape`, plus the bot channel's
  `:ack_timeout` and `:not_connected`). Codes that carry no cross-provider
  meaning keep their raw integer value as the reason. `:code` always preserves
  the raw provider code.

  `:raw` may echo the original response body; it is redacted from `inspect/1`
  output to keep payloads and PII out of logs.
  """

  @type reason ::
          :auth
          | :ip_rejected
          | :rate_limited
          | :invalid_code
          | :not_found
          | :ack_timeout
          | :not_connected
          | :transport
          | :unexpected_shape
          | integer()

  @type t :: %__MODULE__{
          reason: reason(),
          code: integer() | nil,
          message: String.t() | nil,
          http_status: integer() | nil,
          retry_after: non_neg_integer() | nil,
          raw: term()
        }

  defexception [:reason, :code, :message, :http_status, :retry_after, :raw]

  # Token invalid / missing / expired. The request layer invalidates the cached
  # token and retries once on these before surfacing the error.
  @auth_codes [40_014, 41_001, 42_001, 40_001]

  # Caller egress IP is not in the app's trusted-IP list. Permanent until the
  # operator fixes the console configuration.
  @ip_rejected_codes [60_020]

  # API call frequency limits.
  @rate_limited_codes [45_009, 45_033]

  # OAuth code invalid or expired (single-use, 5 minutes).
  @invalid_code_codes [40_029]

  # Target user/department does not exist.
  @not_found_codes [60_111, 60_003]

  @impl true
  def message(%__MODULE__{reason: reason, code: code, message: message}) do
    parts = ["wecom_openapi error: reason=#{inspect(reason)}"]
    parts = if code && code != reason, do: parts ++ ["code=#{inspect(code)}"], else: parts
    parts = if message, do: parts ++ ["message=" <> message], else: parts
    Enum.join(parts, " ")
  end

  @doc "Build a transport-level error from a `Req` or socket failure reason."
  @spec transport(term()) :: t()
  def transport(reason) do
    %__MODULE__{reason: :transport, message: inspect(reason), raw: reason}
  end

  @doc "Build an error from a `{errcode, errmsg}` response body and HTTP status."
  @spec from_body(map(), integer() | nil) :: t()
  def from_body(body, status \\ nil) when is_map(body) do
    code = Map.get(body, "errcode")
    message = Map.get(body, "errmsg")

    %__MODULE__{
      reason: classify(code),
      code: code,
      message: message,
      http_status: status,
      raw: body
    }
  end

  @doc "Build an error from a bot WebSocket ack frame with a non-zero `errcode`."
  @spec from_ack(map()) :: t()
  def from_ack(frame) when is_map(frame) do
    code = Map.get(frame, "errcode")

    %__MODULE__{
      reason: classify(code),
      code: code,
      message: Map.get(frame, "errmsg"),
      raw: frame
    }
  end

  @doc """
  Classify a raw WeCom `errcode` into a stable reason, or return the raw code
  when it carries no cross-provider meaning.
  """
  @spec classify(integer() | nil) :: reason()
  def classify(code) when code in @auth_codes, do: :auth
  def classify(code) when code in @ip_rejected_codes, do: :ip_rejected
  def classify(code) when code in @rate_limited_codes, do: :rate_limited
  def classify(code) when code in @invalid_code_codes, do: :invalid_code
  def classify(code) when code in @not_found_codes, do: :not_found
  def classify(0), do: :unexpected_shape
  def classify(code) when is_integer(code), do: code
  def classify(_code), do: :unexpected_shape

  @doc "Whether the failure is worth retrying with backoff."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{reason: reason})
      when reason in [:rate_limited, :transport, :ack_timeout, :not_connected],
      do: true

  def retryable?(%__MODULE__{http_status: status}) when is_integer(status) and status >= 500,
    do: true

  def retryable?(%__MODULE__{}), do: false

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%WeComOpenAPI.Error{} = error, opts) do
      visible =
        [
          reason: error.reason,
          code: error.code,
          message: error.message,
          http_status: error.http_status,
          retry_after: error.retry_after
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> then(fn fields ->
          if is_nil(error.raw), do: fields, else: fields ++ [raw: :redacted]
        end)

      concat(["#WeComOpenAPI.Error<", to_doc(visible, opts), ">"])
    end
  end
end
