defmodule Ankole.Brain.Dreaming.ResponseFormat do
  @moduledoc false

  @spec stage_a() :: map()
  def stage_a do
    json_schema(
      "brain_stage_a_episode_summary",
      true,
      %{
        "type" => "object",
        "properties" => %{
          "episodes" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "topic" => %{"type" => "string"},
                "question" => nullable_string(),
                "summary" => %{"type" => "string"},
                "resolution" => nullable_string(),
                "systems" => nullable_string_array(),
                "resolution_message" => nullable_string(),
                "messages" => string_array()
              },
              "required" => [
                "topic",
                "question",
                "summary",
                "resolution",
                "systems",
                "resolution_message",
                "messages"
              ],
              "additionalProperties" => false
            }
          },
          "noise_messages" => string_array(),
          "deferred_messages" => string_array()
        },
        "required" => [
          "episodes",
          "noise_messages",
          "deferred_messages"
        ],
        "additionalProperties" => false
      }
    )
  end

  @spec stage_b_locator() :: map()
  def stage_b_locator do
    json_schema(
      "brain_stage_b_locator",
      true,
      %{
        "type" => "object",
        "properties" => %{
          "material_refs" => string_array(),
          "topics" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "query" => %{"type" => "string"},
                "material_refs" => string_array()
              },
              "required" => ["query", "material_refs"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["material_refs", "topics"],
        "additionalProperties" => false
      }
    )
  end

  @spec stage_b_curator([String.t()]) :: map()
  def stage_b_curator(operation_names) when is_list(operation_names) do
    # Operation payloads deliberately contain arbitrary Brain property values.
    # The response format owns the envelope while StageB's existing validator
    # owns each discriminated operation and its domain constraints.
    json_schema(
      "brain_stage_b_curator",
      false,
      %{
        "type" => "object",
        "properties" => %{
          "operations" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "operation" => %{"type" => "string", "enum" => operation_names}
              },
              "required" => ["operation"],
              "additionalProperties" => true
            }
          },
          "skill_updates" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "skill_name" => %{"type" => "string"},
                "mode" => %{"type" => "string", "enum" => ["append", "replace"]},
                "content" => %{"type" => "string"}
              },
              "required" => ["skill_name", "mode", "content"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["operations", "skill_updates"],
        "additionalProperties" => false
      }
    )
  end

  defp json_schema(name, strict, schema) do
    %{
      "format" => %{
        "type" => "json_schema",
        "name" => name,
        "strict" => strict,
        "schema" => schema
      }
    }
  end

  defp string_array, do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp nullable_string, do: %{"type" => ["string", "null"]}

  defp nullable_string_array do
    %{"type" => ["array", "null"], "items" => %{"type" => "string"}}
  end
end
