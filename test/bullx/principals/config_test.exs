defmodule BullX.Principals.ConfigTest do
  use ExUnit.Case, async: false

  alias BullX.Config.Principals

  @env_match_rules "BULLX_PRINCIPALS_AUTHN_MATCH_RULES"

  setup do
    previous = Application.get_env(:bullx, :principals)

    on_exit(fn ->
      System.delete_env(@env_match_rules)
      restore_app_env(previous)
    end)

    :ok
  end

  test "match rules normalize JSON-compatible data" do
    Application.put_env(:bullx, :principals,
      authn_match_rules: [
        %{
          result: "bind_existing_human",
          op: "equals_human_field",
          source_path: "profile.email",
          human_field: "email"
        },
        %{
          result: "allow_create_human",
          op: "email_domain_in",
          source_path: "profile.email",
          domains: ["Example.COM"]
        }
      ]
    )

    assert [
             %{
               "result" => "bind_existing_human",
               "op" => "equals_human_field",
               "source_path" => "profile.email",
               "human_field" => "email"
             },
             %{
               "result" => "allow_create_human",
               "op" => "email_domain_in",
               "source_path" => "profile.email",
               "domains" => ["example.com"]
             }
           ] = Principals.principals_authn_match_rules!()
  end

  test "invalid match rule source falls through to the default" do
    System.put_env(@env_match_rules, ~s([{"result":"bind_existing_human"}]))

    assert Principals.principals_authn_match_rules!() == []
  end

  defp restore_app_env(nil), do: Application.delete_env(:bullx, :principals)
  defp restore_app_env(value), do: Application.put_env(:bullx, :principals, value)
end
