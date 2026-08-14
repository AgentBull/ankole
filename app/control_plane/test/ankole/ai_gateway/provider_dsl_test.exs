defmodule Ankole.AIGateway.ProviderDSLTest do
  use ExUnit.Case, async: true

  test "rejects an encrypted setting outside credential scope" do
    assert_raise ArgumentError, ~r/must use scope: :credential/, fn ->
      defmodule EncryptedConnectionSettingProvider do
        use Ankole.AIGateway.ProviderDSL

        provider "encrypted_connection_setting_provider" do
          setting(:api_key, encrypted: true)
        end
      end
    end
  end
end
