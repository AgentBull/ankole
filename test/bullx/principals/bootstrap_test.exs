defmodule BullX.Principals.BootstrapTest do
  use BullX.DataCase, async: false

  alias BullX.Principals.ActivationCode
  alias BullX.Principals
  alias BullX.Repo

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

  test "setup-in-progress bootstrap code is stable until it expires" do
    assert {:ok, %{code: code, activation_code: row}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert {:ok, hash} = Principals.verify_bootstrap_activation_code_for_setup(code)

    setup_row = Repo.get!(ActivationCode, row.id)
    assert setup_row.code_hash == hash
    assert setup_row.metadata["setup_gate_verified_at"]

    assert {:ok, %{code: nil, activation_code: existing, action: :existing}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert existing.id == row.id
    assert existing.code_hash == hash

    setup_row
    |> Ecto.Changeset.change(%{
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    })
    |> Repo.update!()

    assert {:ok, %{code: refreshed_code, activation_code: refreshed, action: :refreshed}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert refreshed.id == row.id
    assert refreshed_code != code
    refute refreshed.metadata["setup_gate_verified_at"]
  end

  test "bootstrap creation stops after a Human Principal exists" do
    assert {:ok, %{principal: _principal}} =
             Principals.create_human(%{uid: "bootstrap-human", display_name: "Bootstrap Human"})

    assert {:error, :bootstrap_not_required} =
             Principals.create_or_refresh_bootstrap_activation_code()
  end
end
