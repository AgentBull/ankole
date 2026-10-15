defmodule Ankole.AttrsRetryHintTest do
  use ExUnit.Case, async: true

  alias Ankole.Attrs

  describe "reply_delivery_retry_after_seconds/1" do
    test "reads a string-keyed hint" do
      assert Attrs.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => 5}) == 5
    end

    test "reads an atom-keyed hint" do
      assert Attrs.reply_delivery_retry_after_seconds(%{retry_after_seconds: 5}) == 5
    end

    test "SDK errors without a retry hint use the normal retry schedule" do
      error = %FeishuOpenAPI.Error{code: 500_100, msg: "upstream failure", http_status: 200}
      assert Attrs.reply_delivery_retry_after_seconds(error) == 0
    end

    test "defaults to zero when missing, non-positive, or not a map" do
      assert Attrs.reply_delivery_retry_after_seconds(%{}) == 0
      assert Attrs.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => 0}) == 0
      assert Attrs.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => -1}) == 0
      assert Attrs.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => "5"}) == 0
      assert Attrs.reply_delivery_retry_after_seconds(nil) == 0
    end
  end
end
