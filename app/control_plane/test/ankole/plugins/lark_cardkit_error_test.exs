defmodule Ankole.Plugins.LarkAdapter.CardKitErrorTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.CardKit.ErrorPolicy
  alias FeishuOpenAPI.Error

  test "classifies provider failures into retry, reopen, replace, fallback, and blocked actions" do
    assert ErrorPolicy.action(%Error{code: 300_120, msg: "internal"}) == :retry
    assert ErrorPolicy.action(%Error{code: 200_850, msg: "stream timeout"}) == :reopen_stream
    assert ErrorPolicy.action(%Error{code: 300_309, msg: "stream closed"}) == :reopen_stream
    assert ErrorPolicy.action(%Error{code: 200_740, msg: "missing"}) == :replace_card
    assert ErrorPolicy.action(%Error{code: 200_750, msg: "expired"}) == :replace_card
    assert ErrorPolicy.action(%Error{code: 200_860, msg: "too large"}) == :plain_text_fallback

    assert ErrorPolicy.action(%Error{code: 230_072, msg: "edit limit reached"}) ==
             :plain_text_fallback

    assert ErrorPolicy.action(%Error{
             code: 230_099,
             msg:
               "Failed to create card content; ErrCode: 200780; ErrMsg: card binding biz count over limit"
           }) == :plain_text_fallback

    assert ErrorPolicy.action(%Error{code: 230_099, msg: "unknown card creation failure"}) ==
             :operator_action_required

    assert ErrorPolicy.action(%Error{code: 300_311, msg: "permission"}) ==
             :operator_action_required
  end

  test "network and rate-limit failures stay retryable" do
    assert ErrorPolicy.action(:timeout) == :retry
    assert ErrorPolicy.action(%Error{http_status: 429, msg: "slow down"}) == :retry
    assert ErrorPolicy.action(%Error{http_status: 503, msg: "unavailable"}) == :retry
  end
end
