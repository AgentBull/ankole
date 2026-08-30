defmodule Ankole.SignalsGateway.UtilsTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.Utils

  describe "reply_delivery_retry_after_seconds/1" do
    test "reads a string-keyed hint" do
      assert Utils.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => 5}) == 5
    end

    test "reads an atom-keyed hint" do
      assert Utils.reply_delivery_retry_after_seconds(%{retry_after_seconds: 5}) == 5
    end

    test "defaults to zero when missing, non-positive, or not a map" do
      assert Utils.reply_delivery_retry_after_seconds(%{}) == 0
      assert Utils.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => 0}) == 0
      assert Utils.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => -1}) == 0
      assert Utils.reply_delivery_retry_after_seconds(%{"retry_after_seconds" => "5"}) == 0
      assert Utils.reply_delivery_retry_after_seconds(nil) == 0
    end
  end
end
