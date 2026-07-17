defmodule DingTalkOpenAPI.Error do
  @moduledoc """
  Represents a failed DingTalk API call, transport failure, or Stream error.

  DingTalk speaks two error dialects. New-domain (`api.dingtalk.com`) responses
  fail with an HTTP non-2xx status and a `{"code" => "<string>", "message" =>
  "..."}` body. Old-domain (`oapi.dingtalk.com`, `topapi/*`) responses fail with
  HTTP 200 and a `{"errcode" => <integer>, "errmsg" => "..."}` body where a
  non-zero `errcode` is the failure.

  `:reason` folds both dialects into a stable classification atom the adapter can
  branch on (`:rate_limited`, `:quota_exhausted`, `:auth`, `:not_found`,
  `:content_rejected`, `:target_gone`, `:transport`, `:unexpected_shape`). Codes
  that carry no cross-provider meaning keep their raw DingTalk value as the
  reason (the original string or integer). `:code` always preserves the raw
  provider code so callers can inspect the exact value.

  `:raw` may echo the original response body; it is redacted from `inspect/1`
  output to keep payloads and PII out of logs.
  """

  @type reason ::
          :rate_limited
          | :quota_exhausted
          | :auth
          | :not_found
          | :content_rejected
          | :target_gone
          | :transport
          | :unexpected_shape
          | String.t()
          | integer()

  @type t :: %__MODULE__{
          reason: reason(),
          code: String.t() | integer() | nil,
          message: String.t() | nil,
          http_status: integer() | nil,
          retry_after: non_neg_integer() | nil,
          raw: term()
        }

  defexception [:reason, :code, :message, :http_status, :retry_after, :raw]

  # Auth / token failures. New-domain string codes plus the old-domain integer
  # families that mean the same thing.
  @auth_codes ~w(
    token.notExisted
    invalidParameter.token.invalid
    invalidParameter.robotCode.auth
    Forbidden.AccessDenied
    unauthorized
  )

  # Permanent content-safety rejections from the card content review.
  @content_rejected_codes ~w(param.contentUnsafe)

  # The send/card target no longer exists or is disabled. Not retryable.
  @target_gone_codes ~w(
    group.disbanded
    bot.stopped
    template.stopped
    param.cardNotExist
    cardInstanceNotExist
  )

  @impl true
  def message(%__MODULE__{reason: reason, code: code, message: message}) do
    parts = ["dingtalk_openapi error: reason=#{inspect(reason)}"]
    parts = if code && code != reason, do: parts ++ ["code=#{inspect(code)}"], else: parts
    parts = if message, do: parts ++ ["message=" <> message], else: parts
    Enum.join(parts, " ")
  end

  @doc "Build a transport-level error from a `Req` failure reason."
  @spec transport(term()) :: t()
  def transport(reason) do
    %__MODULE__{reason: :transport, message: inspect(reason), raw: reason}
  end

  @doc """
  Build an error from a new-domain response body (`%{"code" => c, "message" =>
  m}`), the HTTP status, and optional `Retry-After`.
  """
  @spec from_new_domain(map(), integer(), non_neg_integer() | nil) :: t()
  def from_new_domain(body, status, retry_after \\ nil) when is_map(body) do
    code = Map.get(body, "code")
    message = Map.get(body, "message") || Map.get(body, "msg")

    %__MODULE__{
      reason: classify(code, status),
      code: code,
      message: message,
      http_status: status,
      retry_after: retry_after,
      raw: body
    }
  end

  @doc """
  Build an error from an old-domain response body (`%{"errcode" => c, "errmsg" =>
  m}`) and the HTTP status.
  """
  @spec from_old_domain(map(), integer()) :: t()
  def from_old_domain(body, status) when is_map(body) do
    code = Map.get(body, "errcode")
    message = Map.get(body, "errmsg")

    %__MODULE__{
      reason: classify(code, status),
      code: code,
      message: message,
      http_status: status,
      raw: body
    }
  end

  @doc """
  Classify a raw DingTalk code (new-domain string or old-domain integer) into a
  stable reason, or return the raw code when it carries no cross-provider
  meaning.
  """
  @spec classify(String.t() | integer() | nil, integer() | nil) :: reason()
  def classify(code, status \\ nil)

  def classify(code, _status) when code in @auth_codes, do: :auth
  def classify(code, _status) when code in @content_rejected_codes, do: :content_rejected
  def classify(code, _status) when code in @target_gone_codes, do: :target_gone

  # Old-domain integer families (documented DingTalk error codes).
  def classify(20_001, _status), do: :quota_exhausted
  def classify(90_018, _status), do: :rate_limited
  def classify(88, _status), do: :rate_limited
  def classify(60_121, _status), do: :not_found
  def classify(40_014, _status), do: :auth
  def classify(42_001, _status), do: :auth
  def classify(0, _status), do: :unexpected_shape

  # New-domain string prefixes that map to rate limiting regardless of the exact
  # suffix (e.g. "requestOverLimit.qps", "flowControl.*").
  def classify("requestOverLimit" <> _rest, _status), do: :rate_limited
  def classify("flowControl" <> _rest, _status), do: :rate_limited

  # HTTP 429 with no more specific body code is still a rate limit.
  def classify(nil, 429), do: :rate_limited
  def classify(_code, 429), do: :rate_limited

  # Otherwise keep the raw provider code as the reason.
  def classify(code, _status), do: code

  @doc "Whether the failure is worth retrying with backoff."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{reason: reason}) when reason in [:rate_limited, :transport], do: true

  def retryable?(%__MODULE__{http_status: status}) when is_integer(status) and status >= 500,
    do: true

  def retryable?(%__MODULE__{}), do: false

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%DingTalkOpenAPI.Error{} = error, opts) do
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

      concat(["#DingTalkOpenAPI.Error<", to_doc(visible, opts), ">"])
    end
  end
end
