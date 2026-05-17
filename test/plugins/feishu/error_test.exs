defmodule Feishu.ErrorTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Error, as: OpenAPIError

  test "maps practical Feishu auth and payload codes" do
    assert %{"kind" => "auth"} = Feishu.Error.map(%OpenAPIError{code: 10_012})
    assert %{"kind" => "auth"} = Feishu.Error.map(%OpenAPIError{code: 514})
    assert %{"kind" => "auth"} = Feishu.Error.map(%OpenAPIError{code: 1_000_040_350})
    assert %{"kind" => "payload"} = Feishu.Error.map(%OpenAPIError{code: :bad_path})
    assert %{"kind" => "payload"} = Feishu.Error.map(%OpenAPIError{code: :bad_file})
    assert %{"kind" => "payload"} = Feishu.Error.map(%OpenAPIError{code: :unexpected_shape})
  end

  test "preserves safe retry hints for rate limits" do
    assert %{
             "kind" => "rate_limit",
             "details" => %{"retry_after_ms" => 3000}
           } =
             Feishu.Error.map(%OpenAPIError{
               code: :rate_limited,
               http_status: 429,
               details: %{"retry_after_ms" => 3000}
             })
  end
end
