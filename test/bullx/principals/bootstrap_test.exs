defmodule BullX.Principals.BootstrapTest do
  use BullX.DataCase, async: false

  alias BullX.Principals

  test "bootstrap activation code can be refreshed and verified before consumption" do
    assert {:ok, %{code: first_code, activation_code: first_row, action: first_action}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert first_action in [:created, :refreshed]
    assert Principals.bootstrap_activation_code_pending?()
    assert {:ok, hash} = Principals.verify_bootstrap_activation_code(first_code)
    assert Principals.bootstrap_activation_code_valid_for_hash?(hash)

    assert {:ok, %{code: second_code, activation_code: second_row, action: :refreshed}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert second_row.id == first_row.id
    assert second_code != first_code
  end

  test "bootstrap creation stops after a Human Principal exists" do
    assert {:ok, %{principal: _principal}} =
             Principals.create_human(%{uid: "bootstrap-human", display_name: "Bootstrap Human"})

    assert {:error, :bootstrap_not_required} =
             Principals.create_or_refresh_bootstrap_activation_code()
  end
end
