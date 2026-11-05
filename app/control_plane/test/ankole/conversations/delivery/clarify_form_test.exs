defmodule Ankole.Conversations.Delivery.ClarifyFormTest do
  use Ankole.DataCase, async: true

  alias Ankole.Conversations.Delivery.ClarifyForm

  @fields [
    %{
      "id" => "quantity",
      "label" => "Quantity",
      "type" => "number",
      "integer" => true,
      "min" => 1,
      "max" => 500,
      "unit" => "kg"
    },
    %{
      "id" => "ship_date",
      "label" => "Ship date",
      "type" => "date",
      "min" => "2026-11-05",
      "max" => "2026-12-31"
    },
    %{
      "id" => "warehouses",
      "label" => "Warehouses",
      "type" => "multi_select",
      "max_items" => 2,
      "options" => [
        %{"value" => "us_west", "label" => "US West"},
        %{"value" => "us_east", "label" => "US East"},
        %{"value" => "eu", "label" => "EU"}
      ]
    },
    %{
      "id" => "note",
      "label" => "Note",
      "type" => "text",
      "required" => false,
      "max_length" => 10
    },
    %{"id" => "rush", "label" => "Rush", "type" => "boolean", "default" => false}
  ]

  test "normalizes a definition with type defaults and validated defaults" do
    assert {:ok, [quantity, date, warehouses, note, rush]} = ClarifyForm.definition(@fields)
    assert quantity["required"] and quantity["integer"] and quantity["unit"] == "kg"
    assert date["min"] == "2026-11-05"
    assert warehouses["max_items"] == 2

    assert note == %{
             "id" => "note",
             "label" => "Note",
             "type" => "text",
             "required" => false,
             "max_length" => 10,
             "multiline" => false
           }

    assert rush["default"] == false

    assert ClarifyForm.definition(elem(ClarifyForm.definition(@fields), 1)) ==
             ClarifyForm.definition(@fields)
  end

  test "rejects an invalid definition with a precise message for the model" do
    [quantity, date, warehouses | _] = @fields

    for {fields, message} <- [
          {[quantity, quantity], "fields repeats id \"quantity\""},
          {[%{quantity | "id" => "Quantity"}], "fields[0].id must be snake_case"},
          {[Map.merge(quantity, %{"min" => 9, "max" => 1})],
           "fields[0] has a minimum greater than its maximum"},
          {[%{date | "min" => "2026-13-01"}], "fields[0].min must be a YYYY-MM-DD date"},
          {[Map.put(quantity, "default", 2.5)], "fields[0].default is not a valid number value"},
          {[Map.put(warehouses, "default", ["mars"])],
           "fields[0].default is not a valid multi_select value"},
          {[%{warehouses | "options" => [hd(warehouses["options"]), hd(warehouses["options"])]}],
           "fields[0].options repeats value \"us_west\""},
          {[%{"id" => "x", "label" => "X", "type" => "select", "options" => []}],
           "fields[0].options must list 2 to 10 options"},
          {List.duplicate(quantity, 6), "fields must list 1 to 5 fields"},
          {[Map.put(quantity, "required", false)],
           "fields must include at least one required field"}
        ] do
      assert {:error, error} = ClarifyForm.definition(fields)
      assert error =~ message
    end
  end

  test "trims date bounds to ISO dates" do
    [_quantity, date | _] = @fields

    assert {:ok, [%{"min" => "2026-11-05", "max" => "2026-12-31"}]} =
             ClarifyForm.definition([%{date | "min" => " 2026-11-05 ", "max" => "2026-12-31\n"}])
  end

  test "validates answers per field without echoing values and builds a readable summary" do
    {:ok, fields} = ClarifyForm.definition(@fields)

    assert {:error, errors} =
             ClarifyForm.answer(fields, %{
               "quantity" => 2.5,
               "ship_date" => "2026-02-30",
               "warehouses" => ["us_west", "us_east", "eu"],
               "note" => "far too long for this",
               "rush" => "yes"
             })

    assert errors == %{
             "quantity" => "not_an_integer",
             "ship_date" => "invalid_date",
             "warehouses" => "too_many",
             "note" => "too_long",
             "rush" => "invalid"
           }

    assert {:error,
            %{
              "quantity" => "out_of_range",
              "ship_date" => "out_of_range",
              "warehouses" => "not_an_option",
              "rush" => "required"
            }} =
             ClarifyForm.answer(fields, %{
               "quantity" => 501,
               "ship_date" => "2026-11-01",
               "warehouses" => ["mars"]
             })

    assert {:error,
            %{
              "quantity" => "required",
              "ship_date" => "required",
              "warehouses" => "required",
              "rush" => "required"
            }} =
             ClarifyForm.answer(fields, nil)

    assert {:ok, typed} =
             ClarifyForm.answer(fields, %{
               "quantity" => 300.0,
               "ship_date" => " 2026-11-20 ",
               "warehouses" => ["us_east", "us_west"],
               "note" => "  ",
               "rush" => true,
               "unknown" => "ignored"
             })

    assert typed == %{
             "quantity" => 300,
             "ship_date" => "2026-11-20",
             "warehouses" => ["us_west", "us_east"],
             "rush" => true
           }

    assert ClarifyForm.summary(fields, typed) ==
             "Quantity: 300 kg · Ship date: 2026-11-20 · Warehouses: US West, US East · Rush: Yes"
  end

  test "reads card strings into typed values and names rejected fields" do
    {:ok, fields} = ClarifyForm.definition(@fields)

    # Lark submits a list and a dated time zone; Teams submits comma-joined text.
    lark = %{
      "quantity" => "300",
      "ship_date" => "2026-11-20 +0800",
      "warehouses" => ["us_east"],
      "note" => "",
      "rush" => "true"
    }

    assert {:ok, %{"quantity" => 300, "ship_date" => "2026-11-20", "rush" => true}} =
             ClarifyForm.answer(fields, ClarifyForm.card_values(fields, lark))

    teams = %{"quantity" => "2.5", "ship_date" => "", "warehouses" => "us_west,eu,us_east"}

    assert {:error, errors} = ClarifyForm.answer(fields, ClarifyForm.card_values(fields, teams))

    assert errors == %{
             "quantity" => "not_an_integer",
             "ship_date" => "required",
             "warehouses" => "too_many",
             "rush" => "required"
           }

    assert ClarifyForm.error_text(fields, errors) ==
             "Fix these answers and submit again: Quantity (not a whole number), " <>
               "Ship date (required), Warehouses (too many choices), Rush (required)"

    assert ClarifyForm.card_values(fields, nil) == %{}
  end
end
