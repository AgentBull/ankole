defmodule WeComOpenAPI.ErrorTest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.Error

  test "classifies documented errcode families" do
    assert Error.classify(40_014) == :auth
    assert Error.classify(41_001) == :auth
    assert Error.classify(42_001) == :auth
    assert Error.classify(60_020) == :ip_rejected
    assert Error.classify(45_009) == :rate_limited
    assert Error.classify(40_029) == :invalid_code
    assert Error.classify(60_111) == :not_found
  end

  test "unknown codes keep their raw integer as the reason" do
    assert Error.classify(301_058) == 301_058
  end

  test "from_ack keeps the raw code and classifies" do
    error = Error.from_ack(%{"errcode" => 45_009, "errmsg" => "freq out of limit"})
    assert error.reason == :rate_limited
    assert error.code == 45_009
    assert error.message == "freq out of limit"
  end

  test "retryable covers rate limits, transport, and bot channel transients" do
    assert Error.retryable?(%Error{reason: :rate_limited})
    assert Error.retryable?(%Error{reason: :transport})
    assert Error.retryable?(%Error{reason: :ack_timeout})
    assert Error.retryable?(%Error{reason: :not_connected})
    refute Error.retryable?(%Error{reason: :auth})
    refute Error.retryable?(%Error{reason: :ip_rejected})
  end

  test "inspect redacts the raw payload" do
    rendered = inspect(%Error{reason: :auth, code: 40_014, raw: %{"secret" => "leak"}})
    refute rendered =~ "leak"
    assert rendered =~ ":redacted"
  end
end
