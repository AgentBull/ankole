defmodule BullX.Setup.ProjectionTest do
  use BullX.DataCase, async: false

  alias BullX.AuthZ
  alias BullX.Principals
  alias BullX.Setup.Projection

  test "missing setup session redirects to the setup gate" do
    assert {:missing_session, %{redirect_to: "/setup/sessions/new"}} =
             Projection.state_for_session(%{})
  end

  test "valid setup hash keeps the bootstrap code unconsumed and clamps future steps" do
    assert {:ok, %{code: plaintext, code_hash: code_hash}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert {:ok, ^code_hash} = Principals.verify_bootstrap_activation_code_for_setup(plaintext)

    assert {:pending, projection} =
             Projection.state_for_session(%{
               bootstrap_activation_code_hash: code_hash,
               setup_step: "event_routing"
             })

    assert projection.status == :pending
    assert step_index(projection.current_step) < step_index(:event_routing)
    assert projection.current_step == projection.earliest_incomplete_step
    assert projection.current_path == Projection.step_path(projection.current_step)
  end

  test "root init completes setup projection" do
    assert {:ok, %{code: plaintext}} = Principals.create_or_refresh_bootstrap_activation_code()
    assert {:ok, code_hash} = Principals.verify_bootstrap_activation_code_for_setup(plaintext)

    assert {:ok, principal, _identity} =
             Principals.root_init_with_bootstrap_code(plaintext, %{
               adapter: "feishu",
               channel_id: "main",
               external_id: "ou_setup_admin",
               profile: %{"display_name" => "Setup Admin", "email" => "setup@example.com"}
             })

    assert {:completed, projection} =
             Projection.state_for_session(%{
               bootstrap_activation_code_hash: code_hash,
               setup_step: "activate_admin"
             })

    assert projection.status == :completed

    assert Projection.activation_status_for_session(%{bootstrap_activation_code_hash: code_hash}) ==
             :complete

    assert {:ok, groups} = AuthZ.list_principal_groups(principal)
    assert Enum.any?(groups, &(&1.name == "admin" and &1.built_in))
    assert Enum.any?(groups, &(&1.name == "all_humans" and &1.built_in))
  end

  defp step_index(step), do: Enum.find_index(BullX.Setup.steps(), &(&1 == step))
end
