defmodule Ankole.Authn.SMTPFixtureTest do
  use ExUnit.Case, async: true
  alias Ankole.Authn.SMTPFixture

  test "each start writes its own CA file, which stop removes" do
    first = SMTPFixture.start(self())
    second = SMTPFixture.start(self())

    assert first.ca_path != second.ca_path
    assert first.ca_path =~ System.pid()
    assert File.exists?(first.ca_path) and File.exists?(second.ca_path)

    SMTPFixture.stop(first)
    SMTPFixture.stop(second)

    refute File.exists?(first.ca_path)
    refute File.exists?(second.ca_path)
  end
end
