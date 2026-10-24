defmodule Ankole.Authn.DeclarationContractsTest do
  use ExUnit.Case, async: false

  test "strategy declarations reject duplicate names and tenant-scoped email codes" do
    for {definition, expected} <- [
          {"otp(:email, sender: Ankole.Authn.Mailer); otp(:email, sender: Ankole.Authn.Mailer)",
           ~r/Multiple actions.*email_request/s},
          {"otp(:email, scope: :tenant, sender: Ankole.Authn.Mailer)", ~r/scope/}
        ] do
      name = "Ankole.Authn.ContractProbe#{System.unique_integer([:positive])}"

      assert_raise Spark.Error.DslError, expected, fn ->
        Code.compile_string("""
        defmodule #{name} do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Simple,
            extensions: [Ankole.Authn]
          resource do require_primary_key?(false) end
          authn do strategies do #{definition} end end
        end
        """)
      end
    end
  end

  test "runtime dispatch and lifecycle additions use the resource declarations" do
    assert %{scope: :site, provider_id: "email_otp"} =
             Ankole.Authn.Info.strategy(Ankole.Principals.SiteCredential, :email_otp)

    assert %{scope: :tenant} =
             Ankole.Authn.Info.strategy(Ankole.Principals.ExternalIdentity, :enterprise)

    assert Enum.map(
             Spark.Dsl.Extension.get_entities(Ankole.Principals.Principal, [:authn, :add_ons]),
             & &1.name
           ) ==
             [:offboarding_release, :site_credential_binding, :pod_invitation]
  end
end
