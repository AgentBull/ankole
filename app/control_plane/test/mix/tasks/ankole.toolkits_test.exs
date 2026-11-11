defmodule Mix.Tasks.Ankole.ToolkitsTest do
  use ExUnit.Case, async: true

  alias Ankole.Connectors.ToolSpec
  alias Mix.Tasks.Ankole.Toolkits

  test "render_toolkit_declarations splits per-platform modules and composes a barrel index" do
    tools = [
      %ToolSpec{
        toolkit: "github",
        name: "create_issue",
        description: "Create an issue",
        input_schema: %{
          "$defs" => %{
            "Label" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}},
              "required" => ["name"]
            }
          },
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "labels" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/Label"}}
          },
          "required" => ["title"],
          "additionalProperties" => false
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "integer", "format" => "int64"},
            "number" => %{"type" => "integer"}
          },
          "required" => ["id", "number"],
          "additionalProperties" => false
        },
        operation: %{method: :post, path: "/issues"}
      },
      %ToolSpec{
        toolkit: "google_calendar",
        name: "list_events",
        description: "List calendar events",
        input_schema: %{
          "type" => "object",
          "properties" => %{"calendar_id" => %{"type" => "string"}},
          "required" => ["calendar_id"],
          "additionalProperties" => false
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{"items" => %{"type" => "array", "items" => %{"type" => "object"}}},
          "required" => ["items"],
          "additionalProperties" => false
        },
        operation: %{method: :get, path: "/events"}
      }
    ]

    rendered = Toolkits.render_toolkit_declarations(tools)

    assert Map.keys(rendered) |> Enum.sort() == [
             "github.d.ts",
             "google_calendar.d.ts",
             "index.d.ts"
           ]

    github = rendered["github.d.ts"]
    assert github =~ "export interface Inputs"
    assert github =~ "export interface Outputs"
    assert github =~ "export type Tool = keyof Inputs;"
    assert github =~ "Toolkit_github_create_issue_input_schema_1"
    # int64 wire schema maps to string in public output types
    assert github =~ ~s("id": string;)
    refute github =~ "google_calendar"

    barrel = rendered["index.d.ts"]

    assert barrel =~
             ~s(import type { Inputs as Toolkit_github_Inputs, Outputs as Toolkit_github_Outputs } from "./github";)

    assert barrel =~
             ~s(import type { Inputs as Toolkit_google_calendar_Inputs, Outputs as Toolkit_google_calendar_Outputs } from "./google_calendar";)

    assert barrel =~ "export interface ToolkitInputs"
    assert barrel =~ "export interface ToolkitOutputs"
    assert barrel =~ "export type Toolkit = keyof ToolkitInputs;"
    assert barrel =~ "export type ToolkitTool<T extends Toolkit> = keyof ToolkitInputs[T];"
    refute barrel =~ "create_issue"
  end
end
