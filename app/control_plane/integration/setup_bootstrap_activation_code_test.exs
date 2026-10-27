defmodule Ankole.SetupBootstrapActivationCodeTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  test "the operator command starts its dependencies in a cold VM" do
    {output, status} =
      System.cmd("mix", ["ankole.setup.bootstrap_activation_code"],
        cd: File.cwd!(),
        env: [{"PHX_SERVER", "false"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/Setup|SETUP/
    refute output =~ "unknown registry"
  end
end
