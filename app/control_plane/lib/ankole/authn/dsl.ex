defmodule Ankole.Authn.Dsl do
  @moduledoc false
  def sections do
    [
      %Spark.Dsl.Section{
        name: :authn,
        sections: [
          %Spark.Dsl.Section{
            name: :strategies,
            entities: [
              %Spark.Dsl.Entity{
                name: :otp,
                target: Ankole.Authn.Strategies.Otp,
                args: [:name],
                modules: [:sender],
                schema: [
                  name: [type: :atom, required: true],
                  scope: [type: {:in, [:site]}, default: :site],
                  provider_id: [type: {:in, ["email_otp"]}, default: "email_otp"],
                  sender: [
                    type: {:spark_behaviour, Ankole.Authn.Sender},
                    required: true
                  ]
                ]
              },
              %Spark.Dsl.Entity{
                name: :oidc,
                target: Ankole.Authn.Strategies.Oidc,
                args: [:name],
                schema: [
                  name: [type: :atom, required: true],
                  scope: [type: {:in, [:tenant]}, default: :tenant],
                  provider_id: [
                    type: {:in, [:dynamic_tenant_provider]},
                    default: :dynamic_tenant_provider
                  ]
                ]
              }
            ]
          },
          %Spark.Dsl.Section{
            name: :add_ons,
            entities: [
              %Spark.Dsl.Entity{
                name: :add_on,
                target: Ankole.Authn.AddOn,
                args: [:name, :module],
                modules: [:module],
                schema: [
                  name: [type: :atom, required: true],
                  module: [type: {:spark_behaviour, Ankole.Authn.AddOn}, required: true]
                ]
              }
            ]
          }
        ]
      }
    ]
  end
end
