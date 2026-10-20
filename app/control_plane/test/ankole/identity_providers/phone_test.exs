defmodule Ankole.IdentityProviders.PhoneTest do
  use ExUnit.Case, async: true

  alias Ankole.IdentityProviders.Phone

  test "keeps international numbers before considering the China fallback" do
    assert Phone.normalize_china_mobile(" +1 415 555 2671 ") == "+14155552671"
    assert Phone.normalize_china_mobile("+86 138 0000 0000") == "+8613800000000"
  end

  test "accepts Chinese national mobile numbers with optional formatting" do
    assert Phone.normalize_china_mobile("13800000000") == "+8613800000000"
    assert Phone.normalize_china_mobile(" 138 0000 0000 ") == "+8613800000000"
  end

  test "leaves missing and invalid numbers absent" do
    for value <- [nil, "", " ", "not a phone", "4155552671", "1380000000"] do
      assert Phone.normalize_china_mobile(value) == nil
    end
  end
end
