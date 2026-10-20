defmodule IMTransport.HTTPTest do
  use ExUnit.Case, async: true

  alias IMTransport.HTTP

  test "JSON decoding preserves empty, invalid, and already decoded bodies" do
    assert HTTP.decoded_body(~s({"value":[1,true]})) == %{"value" => [1, true]}
    assert HTTP.decoded_body("null") == nil
    assert HTTP.decoded_body("") == ""
    assert HTTP.decoded_body("not-json") == "not-json"
    assert HTTP.decoded_body(nil) == nil
    assert HTTP.decoded_body(%{"code" => 0}) == %{"code" => 0}
  end

  test "an explicit JSON body takes precedence over form data and preserves headers" do
    request =
      HTTP.put_body([headers: [{"authorization", "Bearer token"}]], body: nil, form: [a: 1])

    assert request[:body] == "null"

    assert request[:headers] == [
             {"authorization", "Bearer token"},
             {"content-type", "application/json"}
           ]

    refute Keyword.has_key?(request, :form)
    form = HTTP.put_body([headers: []], form: [a: 1])
    assert form[:form] == [a: 1]
    assert form[:headers] == []
    assert HTTP.put_body([headers: []], []) == [headers: []]
  end

  test "Retry-After retains the clients' seconds and integer-prefix parsing contract" do
    assert HTTP.retry_after(Req.Response.new(headers: [{"retry-after", "12"}])) == 12
    assert HTTP.retry_after(Req.Response.new(headers: [{"retry-after", "3 seconds"}])) == 3
    assert HTTP.retry_after(Req.Response.new(headers: [{"retry-after", "tomorrow"}])) == nil
    assert HTTP.retry_after(Req.Response.new()) == nil
  end

  test "download names retain quoted and encoded content-disposition behavior" do
    response =
      Req.Response.new(
        headers: [{"content-disposition", "attachment; filename*=UTF-8''report%20one.txt"}]
      )

    assert HTTP.filename_from_response(response) == "report one.txt"

    response =
      Req.Response.new(headers: [{"content-disposition", "attachment; filename=\"report.txt\""}])

    assert HTTP.filename_from_response(response) == "report.txt"
    assert HTTP.filename_from_response(Req.Response.new()) == nil
  end
end
