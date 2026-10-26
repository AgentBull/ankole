defmodule Ankole.BackgroundAgentJobs.ConsoleMessage do
  @moduledoc "A sanitized ChatML message in the operator Turn trajectory."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONMap
  use AshJsonApi.Type

  @schema %{
    "oneOf" => [
      %{
        "additionalProperties" => true,
        "properties" => %{
          "content" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "items" => %{
                  "additionalProperties" => true,
                  "properties" => %{"type" => %{"type" => "string"}},
                  "required" => ["type"],
                  "type" => "object"
                },
                "type" => "array"
              }
            ]
          },
          "id" => %{"type" => "string"},
          "metadata" => %{"additionalProperties" => true, "type" => "object"},
          "role" => %{"enum" => ["user", "developer"], "type" => "string"}
        },
        "required" => ["role", "content"],
        "type" => "object"
      },
      %{
        "additionalProperties" => true,
        "properties" => %{
          "content" => %{"type" => "string"},
          "id" => %{"type" => "string"},
          "metadata" => %{"additionalProperties" => true, "type" => "object"},
          "role" => %{"enum" => ["assistant"], "type" => "string"},
          "tool_calls" => %{
            "items" => %{
              "additionalProperties" => true,
              "properties" => %{
                "function" => %{
                  "additionalProperties" => true,
                  "properties" => %{
                    "arguments" => %{"type" => "string"},
                    "name" => %{"type" => "string"},
                    "namespace" => %{"type" => "string"}
                  },
                  "required" => ["name", "arguments"],
                  "type" => "object"
                },
                "id" => %{"type" => "string"},
                "type" => %{"enum" => ["function"], "type" => "string"}
              },
              "required" => ["id", "type", "function"],
              "type" => "object"
            },
            "type" => "array"
          }
        },
        "required" => ["role", "content"],
        "type" => "object"
      },
      %{
        "additionalProperties" => true,
        "properties" => %{
          "content" => %{"type" => "string"},
          "id" => %{"type" => "string"},
          "metadata" => %{"additionalProperties" => true, "type" => "object"},
          "name" => %{"type" => "string"},
          "namespace" => %{"type" => "string"},
          "role" => %{"enum" => ["tool"], "type" => "string"},
          "tool_call_id" => %{"type" => "string"}
        },
        "required" => ["role", "tool_call_id", "name", "content"],
        "type" => "object"
      }
    ]
  }
  @impl AshJsonApi.Type
  def json_schema(_constraints), do: %OpenApiSpex.Schema{oneOf: @schema["oneOf"]}
  @impl AshJsonApi.Type
  def json_write_schema(_constraints), do: @schema
end
