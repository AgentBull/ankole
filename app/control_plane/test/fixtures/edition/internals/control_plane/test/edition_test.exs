defmodule Ankole.EditionFixture.Test do
  use ExUnit.Case

  test "the selected source build includes private test support" do
    assert Ankole.EditionFixture.TestSupport.compiled?()

    assert Enum.any?(
             Mix.Project.config()[:test_paths],
             &String.ends_with?(&1, "internals/control_plane/test")
           )

    assert Ankole.IdentityProviders.SiteSources.registered?("fixture-site")
  end
end
