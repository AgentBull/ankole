defmodule BullXWeb.I18n.ErrorTranslatorTest do
  use ExUnit.Case, async: false

  alias BullX.I18n.Resolver
  alias BullXWeb.I18n.ErrorTranslator

  setup do
    Resolver.put_catalog(
      :"en-US",
      %{
        "errors.validation.length.string.min" => """
        .input {$count :integer}
        .match $count
          1 {{should be at least 1 character}}
          * {{should be at least {$count} characters}}
        """,
        "errors.validation.number.less_than" => "must be less than {$number}"
      },
      %{}
    )

    Resolver.put_loaded([:"en-US"])

    on_exit(fn -> BullX.I18n.Catalog.reload_locales!() end)

    :ok
  end

  test "translates length validations through the TOML key skeleton" do
    assert ErrorTranslator.translate_error(
             {"should be at least %{count} character(s)",
              [validation: :length, kind: :min, type: :string, count: 2]}
           ) == "should be at least 2 characters"
  end

  test "translates number validations through the TOML key skeleton" do
    assert ErrorTranslator.translate_error(
             {"must be less than %{number}", [validation: :number, kind: :less_than, number: 2]}
           ) == "must be less than 2"
  end
end
