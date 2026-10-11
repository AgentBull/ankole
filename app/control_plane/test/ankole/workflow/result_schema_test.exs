defmodule Ankole.Workflow.ResultSchemaTest do
  use ExUnit.Case, async: true

  alias Ankole.Workflow.ResultSchema

  test "rejects unsupported, nullable, and malformed result schemas" do
    assert {:error, {:unsupported_workflow_schema_keywords, ["$ref"]}} =
             ResultSchema.validate_schema(%{
               "$ref" => "#/components/schemas/Result",
               "type" => "object"
             })

    assert {:error, {:unsupported_workflow_schema_keywords, ["nullable"]}} =
             ResultSchema.validate_schema(%{"type" => "string", "nullable" => true})

    assert {:error, _reason} =
             ResultSchema.validate_schema(%{"type" => "string", "pattern" => "["})
  end

  test "object schemas are recursively closed and require every declared property" do
    strict_schema = %{
      "type" => "object",
      "properties" => %{
        "details" => %{
          "type" => "object",
          "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}},
          "required" => ["count"],
          "additionalProperties" => false
        }
      },
      "required" => ["details"],
      "additionalProperties" => false
    }

    assert :ok = ResultSchema.validate_schema(strict_schema)

    assert {:ok, %{"details" => %{"count" => 1}}} =
             ResultSchema.validate(strict_schema, %{"details" => %{"count" => 1}})

    assert {:error, {:workflow_result_schema_mismatch, _errors}} =
             ResultSchema.validate(strict_schema, %{"details" => %{}})

    assert {:error, {:workflow_result_schema_mismatch, _errors}} =
             ResultSchema.validate(strict_schema, %{
               "details" => %{"count" => 1, "unexpected" => true}
             })

    assert {:error, :invalid_workflow_schema_properties} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "required" => [],
               "additionalProperties" => false
             })

    assert {:error, :invalid_workflow_schema_required} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "properties" => %{},
               "additionalProperties" => false
             })

    assert {:error, :invalid_workflow_schema_additional_properties} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "properties" => %{"value" => %{"type" => "string"}},
               "required" => ["value"]
             })

    assert {:error, :invalid_workflow_schema_required} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "properties" => %{
                 "left" => %{"type" => "string"},
                 "right" => %{"type" => "string"}
               },
               "required" => ["left"],
               "additionalProperties" => false
             })

    assert {:error,
            {:invalid_workflow_schema_property, "details",
             :invalid_workflow_schema_additional_properties}} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "properties" => %{
                 "details" => %{
                   "type" => "object",
                   "properties" => %{"count" => %{"type" => "integer"}},
                   "required" => ["count"],
                   "additionalProperties" => true
                 }
               },
               "required" => ["details"],
               "additionalProperties" => false
             })

    assert {:error, {:unsupported_workflow_schema_keywords, ["maxProperties", "minProperties"]}} =
             ResultSchema.validate_schema(%{
               "type" => "object",
               "properties" => %{},
               "required" => [],
               "additionalProperties" => false,
               "minProperties" => 0,
               "maxProperties" => 0
             })
  end

  test "raw numeric validation enforces constraints that OpenApiSpex skips" do
    assert {:error, {:unsupported_workflow_schema_keywords, ["multipleOf"]}} =
             ResultSchema.validate(%{"type" => "number", "multipleOf" => 2}, 3.0)

    assert {:error, {:workflow_result_minimum, [], 1.5}} =
             ResultSchema.validate(%{"type" => "integer", "minimum" => 1.5}, 1)

    assert {:ok, 4} =
             ResultSchema.validate(%{"type" => "integer", "multipleOf" => 2}, 4)

    assert {:error, {:invalid_workflow_schema_bound, "multipleOf"}} =
             ResultSchema.validate(%{"type" => "integer", "multipleOf" => 2.0}, 4)

    assert {:error, {:workflow_result_multiple_of, [], 2}} =
             ResultSchema.validate(
               %{"type" => "integer", "multipleOf" => 2},
               1_000_000_000_001
             )

    assert {:error, {:workflow_result_minimum, ["count"], 2}} =
             ResultSchema.validate(
               %{
                 "type" => "object",
                 "properties" => %{"count" => %{"type" => "integer", "minimum" => 2}},
                 "required" => ["count"],
                 "additionalProperties" => false
               },
               %{"count" => 1}
             )
  end

  test "enum uses JSON numeric equality and uniqueItems is outside the accepted subset" do
    assert {:ok, 1.0} =
             ResultSchema.validate(%{"type" => "number", "enum" => [1]}, 1.0)

    assert {:error, {:unsupported_workflow_schema_keywords, ["uniqueItems"]}} =
             ResultSchema.validate(
               %{
                 "type" => "array",
                 "items" => %{"type" => "number"},
                 "uniqueItems" => true
               },
               [1, 1.0]
             )
  end

  test "JSON values retain strict numeric types and the original accepted value" do
    for value <- ["4", 4.0] do
      assert {:error, {:workflow_result_type_mismatch, [], "integer"}} =
               ResultSchema.validate(%{"type" => "integer"}, value)
    end

    assert {:ok, 4.0} = ResultSchema.validate(%{"type" => "number"}, 4.0)

    assert {:error, {:workflow_result_multiple_of, [], 2}} =
             ResultSchema.validate(%{"type" => "integer", "multipleOf" => 2}, 1_000_000_000_001)

    assert {:error, {:workflow_result_minimum, [], 1.5}} =
             ResultSchema.validate(%{"type" => "integer", "minimum" => 1.5}, 1)

    assert {:ok, 1.0} = ResultSchema.validate(%{"type" => "number", "enum" => [1]}, 1.0)
  end

  test "string and array lengths retain their structural failure class" do
    assert {:ok, "中文"} =
             ResultSchema.validate(%{"type" => "string", "maxLength" => 2}, "中文")

    assert {:error, {:workflow_result_schema_mismatch, _}} =
             ResultSchema.validate(%{"type" => "string", "minLength" => 2}, "é")

    assert {:error, {:workflow_result_schema_mismatch, _}} =
             ResultSchema.validate(
               %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 1},
               ["a", "b"]
             )

    assert {:error, {:workflow_result_schema_mismatch, _}} =
             ResultSchema.validate(closed_object(%{"count" => %{"type" => "integer"}}), %{
               "count" => 1,
               "extra" => true
             })
  end

  test "empty closed objects work at the root and within a property or array" do
    empty = closed_object(%{})
    assert {:ok, %{}} = ResultSchema.validate(empty, %{})

    assert {:error, {:workflow_result_schema_mismatch, _}} =
             ResultSchema.validate(empty, %{"x" => 1})

    value = %{"meta" => %{}}
    assert {:ok, ^value} = ResultSchema.validate(closed_object(%{"meta" => empty}), value)

    assert {:ok, [%{}]} =
             ResultSchema.validate(%{"type" => "array", "items" => empty}, [%{}])
  end

  test "typed failures preserve nested paths and choose type before enum at the same node" do
    schema =
      closed_object(%{
        "items" => %{
          "type" => "array",
          "items" => closed_object(%{"count" => %{"type" => "integer"}})
        }
      })

    assert {:error, {:workflow_result_type_mismatch, ["items", 1, "count"], "integer"}} =
             ResultSchema.validate(schema, %{"items" => [%{"count" => 1}, %{"count" => 2.0}]})

    assert {:error, {:workflow_result_type_mismatch, [], "string"}} =
             ResultSchema.validate(%{"type" => "string", "enum" => ["a"]}, 5)

    assert {:error, {:workflow_result_type_mismatch, ["a"], "integer"}} =
             ResultSchema.validate(
               closed_object(%{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}}),
               %{"a" => 1.0, "b" => 2.0}
             )

    assert {:error, {:workflow_result_type_mismatch, ["a/b"], "integer"}} =
             ResultSchema.validate(closed_object(%{"a/b" => %{"type" => "integer"}}), %{
               "a/b" => 1.0
             })

    assert {:error, {:workflow_result_minimum, [], 10}} =
             ResultSchema.validate(%{"type" => "integer", "minimum" => 10, "multipleOf" => 3}, 4)
  end

  test "optional null bounds and ambiguous slash property names keep their existing contract" do
    assert {:ok, 1} = ResultSchema.validate(%{"type" => "integer", "minimum" => nil}, 1)

    schema =
      closed_object(%{
        "a" => closed_object(%{"b" => %{"type" => "integer"}}),
        "a/b" => %{"type" => "integer"}
      })

    assert {:error, {:workflow_result_type_mismatch, ["a/b"], "integer"}} =
             ResultSchema.validate(schema, %{"a" => %{"b" => 1}, "a/b" => 1.0})

    assert {:error, {:workflow_result_type_mismatch, ["a", "b"], "integer"}} =
             ResultSchema.validate(schema, %{"a" => %{"b" => 1.0}, "a/b" => 1})
  end

  defp closed_object(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
  end
end
