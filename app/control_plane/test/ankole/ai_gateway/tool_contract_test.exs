defmodule Ankole.AIGateway.ToolContractTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ToolContract
  alias Ankole.AIGateway.ToolContract.Descriptor

  describe "normalize/2" do
    test "preserves one root function contract" do
      parameters = %{
        "type" => "object",
        "properties" => %{"symbol" => %{"type" => "string"}},
        "required" => ["symbol"]
      }

      output_schema = %{
        "type" => "object",
        "properties" => %{"price" => %{"type" => "number"}}
      }

      tool = %{
        "type" => "function",
        "name" => "market",
        "description" => "Read one market quote.",
        "parameters" => parameters,
        "output_schema" => output_schema,
        "strict" => true,
        "allowed_callers" => ["programmatic", "direct"],
        "defer_loading" => true,
        "__ankole_search_text" => "quote price"
      }

      assert {:ok, [descriptor]} = ToolContract.normalize([tool])

      assert descriptor == %Descriptor{
               type: "function",
               name: "market",
               namespace: nil,
               namespace_description: nil,
               description: "Read one market quote.",
               parameters: parameters,
               format: nil,
               output_schema: output_schema,
               strict: true,
               search_text: "quote price",
               allowed_callers: ["direct", "programmatic"],
               deferred?: true,
               codec: :json
             }

      assert ToolContract.response_specs([descriptor]) == [
               %{
                 "type" => "function",
                 "name" => "market",
                 "description" => "Read one market quote.",
                 "parameters" => parameters,
                 "output_schema" => output_schema,
                 "strict" => true
               }
             ]
    end

    test "normalizes a namespaced custom tool without losing its public path" do
      format = %{"type" => "grammar", "syntax" => "lark", "definition" => "start: WORD"}
      output_schema = %{"type" => "string"}

      namespace = %{
        "type" => "namespace",
        "name" => "editor",
        "description" => "Editing tools.",
        "defer_loading" => true,
        "tools" => [
          %{
            "type" => "custom",
            "name" => "apply",
            "description" => "Apply one edit.",
            "format" => format,
            "output_schema" => output_schema,
            "allowed_callers" => ["programmatic"]
          }
        ]
      }

      assert {:ok, [descriptor]} = ToolContract.normalize([namespace])

      assert descriptor.type == "custom"
      assert descriptor.name == "apply"
      assert descriptor.namespace == "editor"
      assert descriptor.namespace_description == "Editing tools."
      assert descriptor.parameters == nil
      assert descriptor.format == format
      assert descriptor.output_schema == output_schema
      assert descriptor.allowed_callers == ["programmatic"]
      assert descriptor.deferred?
      assert descriptor.codec == :text

      assert ToolContract.public_spec(descriptor) == %{
               "type" => "custom",
               "name" => "apply",
               "namespace" => "editor",
               "namespace_description" => "Editing tools.",
               "description" => "Apply one edit.",
               "format" => format,
               "output_schema" => output_schema,
               "allowed_callers" => ["programmatic"],
               "defer_loading" => true
             }

      assert ToolContract.response_specs([descriptor]) == [
               %{
                 "type" => "namespace",
                 "name" => "editor",
                 "description" => "Editing tools.",
                 "tools" => [
                   %{
                     "type" => "custom",
                     "name" => "apply",
                     "description" => "Apply one edit.",
                     "format" => format
                   }
                 ]
               }
             ]

      assert [%{"output_schema" => ^output_schema}] =
               ToolContract.executable_snapshot([descriptor])
    end

    test "preserves root and namespace child declaration order" do
      assert {:ok, descriptors} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "root_first"},
                 %{
                   "type" => "namespace",
                   "name" => "group",
                   "tools" => [
                     %{"type" => "function", "name" => "child_first"},
                     %{"type" => "custom", "name" => "child_second"}
                   ]
                 },
                 %{"type" => "function", "name" => "root_last"}
               ])

      assert Enum.map(descriptors, &{&1.namespace, &1.name}) == [
               {nil, "root_first"},
               {"group", "child_first"},
               {"group", "child_second"},
               {nil, "root_last"}
             ]
    end

    test "uses the Codex default namespace descriptions" do
      assert {:ok, descriptors} =
               ToolContract.normalize([
                 %{
                   "type" => "namespace",
                   "name" => "analysis_tools",
                   "tools" => [%{"type" => "function", "name" => "inspect"}]
                 },
                 %{
                   "type" => "namespace",
                   "name" => "functions",
                   "tools" => [%{"type" => "function", "name" => "default_tool"}]
                 }
               ])

      assert [analysis, functions] = ToolContract.response_specs(descriptors)
      assert analysis["description"] == "Tools in the analysis_tools namespace."
      assert functions["description"] == ""
    end

    test "defaults an omitted caller list to direct execution" do
      assert {:ok, [%Descriptor{allowed_callers: ["direct"]}]} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "weather", "parameters" => %{}}
               ])
    end

    test "treats an explicit null caller list as omitted for every executable leaf" do
      cases = [
        {
          [%{"type" => "function", "name" => "weather", "allowed_callers" => nil}],
          [%{"type" => "function", "name" => "weather"}]
        },
        {
          [%{"type" => "custom", "name" => "apply", "allowed_callers" => nil}],
          [%{"type" => "custom", "name" => "apply"}]
        },
        {
          [
            %{
              "type" => "namespace",
              "name" => "weather",
              "tools" => [
                %{"type" => "function", "name" => "forecast", "allowed_callers" => nil}
              ]
            }
          ],
          [
            %{
              "type" => "namespace",
              "name" => "weather",
              "tools" => [%{"type" => "function", "name" => "forecast"}]
            }
          ]
        }
      ]

      for {explicit_null, omitted} <- cases do
        assert {:ok, [%Descriptor{allowed_callers: ["direct"]}] = explicit_descriptors} =
                 ToolContract.normalize(explicit_null)

        assert {:ok, ^explicit_descriptors} = ToolContract.normalize(omitted)
      end
    end

    test "rejects malformed caller lists instead of widening access" do
      invalid_values = [
        [],
        "programmatic",
        ["programmatic", 1],
        ["programmatic", "unknown"],
        ["direct", "direct"]
      ]

      for value <- invalid_values do
        assert {:error, {:invalid_tool_contract, {:invalid_allowed_callers, "weather", ^value}}} =
                 ToolContract.normalize([
                   %{
                     "type" => "function",
                     "name" => "weather",
                     "allowed_callers" => value
                   }
                 ])
      end
    end

    test "rejects tool types that the emulated program runtime cannot execute" do
      for type <- [
            "mcp",
            "apply_patch",
            "shell",
            "local_shell",
            "code_interpreter",
            "computer_use_preview",
            "image_generation"
          ] do
        assert {:error, {:unsupported_tool_type, ^type}} =
                 ToolContract.normalize([%{"type" => type, "name" => "tool"}])
      end
    end

    test "keeps root and namespace identities distinct even when one-slot aliases would collide" do
      assert {:ok, descriptors} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "a__b"},
                 %{
                   "type" => "namespace",
                   "name" => "a",
                   "tools" => [%{"type" => "function", "name" => "b"}]
                 }
               ])

      assert Enum.map(descriptors, &ToolContract.identity/1) == [{nil, "a__b"}, {"a", "b"}]
    end

    test "protects the synthesized names and accepts an explicit replacement set" do
      for reserved <- ["program", "tool_search"] do
        assert {:error, {:invalid_tool_contract, {:reserved_tool_name, ^reserved}}} =
                 ToolContract.normalize([%{"type" => "function", "name" => reserved}])

        assert {:error, {:invalid_tool_contract, {:reserved_tool_name, ^reserved}}} =
                 ToolContract.normalize([
                   %{
                     "type" => "namespace",
                     "name" => "functions",
                     "tools" => [%{"type" => "function", "name" => reserved}]
                   }
                 ])
      end

      assert {:ok, [%Descriptor{name: "find_tools"}]} =
               ToolContract.normalize(
                 [%{"type" => "function", "name" => "find_tools"}],
                 reserved_names: ["program", "find_tools_internal"]
               )

      assert {:error, {:invalid_tool_contract, {:reserved_tool_name, "find_tools"}}} =
               ToolContract.normalize(
                 [%{"type" => "function", "name" => "find_tools"}],
                 reserved_names: ["program", "find_tools"]
               )
    end

    test "rejects names that the Responses API cannot accept" do
      assert {:error, {:invalid_tool_contract, {:invalid_responses_identifier, :tool, "a.b"}}} =
               ToolContract.normalize([%{"type" => "function", "name" => "a.b"}])

      assert {:error,
              {:invalid_tool_contract, {:invalid_responses_identifier, :namespace, "extension/"}}} =
               ToolContract.normalize([
                 %{
                   "type" => "namespace",
                   "name" => "extension/",
                   "description" => "Extension tools.",
                   "tools" => [%{"type" => "function", "name" => "valid"}]
                 }
               ])

      assert {:error, {:invalid_tool_contract, {:invalid_responses_identifier, :tool, "运行😀"}}} =
               ToolContract.normalize([
                 %{
                   "type" => "namespace",
                   "name" => "extension",
                   "description" => "Extension tools.",
                   "tools" => [%{"type" => "function", "name" => "运行😀"}]
                 }
               ])
    end

    test "rejects duplicate leaves across root and the Codex default namespace" do
      assert {:error, {:invalid_tool_contract, {:duplicate_public_tool, "functions.lookup"}}} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "lookup"},
                 %{
                   "type" => "namespace",
                   "name" => "functions",
                   "tools" => [%{"type" => "function", "name" => "lookup"}]
                 }
               ])
    end

    test "rejects conflicting descriptions for one namespace container" do
      assert {:error,
              {:invalid_tool_contract, {:namespace_description_mismatch, "collaboration"}}} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "namespace" => "collaboration",
                   "namespace_description" => "First description.",
                   "name" => "spawn_agent"
                 },
                 %{
                   "type" => "function",
                   "namespace" => "collaboration",
                   "namespace_description" => "Second description.",
                   "name" => "send_message"
                 }
               ])
    end

    test "rejects ambiguous function and custom input contracts" do
      assert {:error,
              {:invalid_tool_contract, {:function_format_unsupported, "f", %{"type" => "text"}}}} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "f", "format" => %{"type" => "text"}}
               ])

      assert {:error,
              {:invalid_tool_contract,
               {:custom_parameters_unsupported, "c", %{"type" => "object"}}}} =
               ToolContract.normalize([
                 %{
                   "type" => "custom",
                   "name" => "c",
                   "parameters" => %{"type" => "object"}
                 }
               ])
    end

    test "preserves the upstream output schema without narrowing its vocabulary" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$defs" => %{
          "score" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
        },
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "string", "minLength" => 1},
          "score" => %{"$ref" => "#/$defs/score"}
        },
        "required" => ["value"],
        "additionalProperties" => false
      }

      assert {:ok, [%Descriptor{output_schema: ^schema}]} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "bounded", "output_schema" => schema}
               ])
    end

    test "rejects a non-object output schema envelope" do
      assert {:error,
              {:invalid_tool_contract,
               {:invalid_map_field, "bounded", "output_schema", ["not", "an", "object"]}}} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "bounded",
                   "output_schema" => ["not", "an", "object"]
                 }
               ])
    end
  end

  describe "executable_snapshot/1 and fingerprint/1" do
    test "are stable across tool and map construction order" do
      left = [
        %{
          "type" => "function",
          "name" => "b",
          "parameters" => %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}},
            "type" => "object"
          }
        },
        %{"type" => "custom", "name" => "a", "format" => %{"type" => "text"}}
      ]

      right = [
        %{"format" => %{"type" => "text"}, "name" => "a", "type" => "custom"},
        %{
          "name" => "b",
          "type" => "function",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"]
          }
        }
      ]

      assert {:ok, left_descriptors} = ToolContract.normalize(left)
      assert {:ok, right_descriptors} = ToolContract.normalize(right)

      assert ToolContract.executable_snapshot(left_descriptors) ==
               ToolContract.executable_snapshot(right_descriptors)

      assert ToolContract.fingerprint(left_descriptors) ==
               ToolContract.fingerprint(right_descriptors)
    end

    test "changes when one executable schema changes" do
      assert {:ok, first} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "lookup",
                   "parameters" => %{"type" => "object"}
                 }
               ])

      assert {:ok, second} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "lookup",
                   "parameters" => %{"type" => "array"}
                 }
               ])

      refute ToolContract.fingerprint(first) == ToolContract.fingerprint(second)
    end
  end

  describe "validate_loaded/2" do
    test "accepts a frozen catalog member and rejects an atomic mixed list" do
      catalog_specs = [
        %{
          "type" => "namespace",
          "name" => "mcp__finance",
          "description" => "Financial tools.",
          "tools" => [
            %{
              "type" => "function",
              "name" => "quote",
              "parameters" => %{"type" => "object"},
              "allowed_callers" => ["direct", "programmatic"],
              "defer_loading" => true
            }
          ]
        }
      ]

      assert {:ok, catalog} = ToolContract.normalize(catalog_specs)
      assert {:ok, loaded} = ToolContract.validate_loaded(catalog_specs, known: catalog)
      assert loaded == catalog

      malformed =
        catalog_specs ++
          [
            %{
              "type" => "function",
              "name" => "broken",
              "allowed_callers" => ["direct", "admin"]
            }
          ]

      assert {:error,
              {:invalid_tool_contract, {:invalid_allowed_callers, "broken", ["direct", "admin"]}}} =
               ToolContract.validate_loaded(malformed, known: catalog)
    end

    test "rejects a loaded redefinition of a frozen public identity" do
      assert {:ok, known} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "lookup",
                   "parameters" => %{"type" => "object"},
                   "defer_loading" => true
                 }
               ])

      assert {:error, {:invalid_tool_contract, {:loaded_tool_mismatch, "lookup"}}} =
               ToolContract.validate_loaded(
                 [
                   %{
                     "type" => "function",
                     "name" => "lookup",
                     "parameters" => %{"type" => "array"},
                     "defer_loading" => true
                   }
                 ],
                 known: known
               )
    end

    test "restores private search text from an unchanged public replay" do
      spec = %{
        "type" => "function",
        "name" => "lookup",
        "description" => "Lookup a marker",
        "parameters" => %{"type" => "object"},
        "defer_loading" => true,
        "__ankole_search_text" => "private catalog ranking text"
      }

      assert {:ok, [known]} = ToolContract.normalize([spec])

      public_replay = Map.delete(spec, "__ankole_search_text")

      assert {:ok, [^known]} =
               ToolContract.validate_loaded([public_replay], known: [known])

      changed_search_text =
        Map.put(public_replay, "__ankole_search_text", "changed private ranking text")

      assert {:error, {:invalid_tool_contract, {:loaded_tool_mismatch, "lookup"}}} =
               ToolContract.validate_loaded([changed_search_text], known: [known])
    end

    test "reconciles a root tool loaded through the Codex functions namespace" do
      assert {:ok, [known]} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "lookup",
                   "description" => "Lookup a marker",
                   "defer_loading" => true
                 }
               ])

      assert {:ok, [^known]} =
               ToolContract.validate_loaded(
                 [
                   %{
                     "type" => "namespace",
                     "name" => "functions",
                     "description" => "",
                     "tools" => [
                       %{
                         "type" => "function",
                         "name" => "lookup",
                         "description" => "Lookup a marker",
                         "defer_loading" => true
                       }
                     ]
                   }
                 ],
                 known: [known]
               )
    end

    test "reconciles an implicit namespace description with the Codex default" do
      assert {:ok, [known]} =
               ToolContract.normalize([
                 %{
                   "type" => "namespace",
                   "name" => "analysis_tools",
                   "tools" => [
                     %{
                       "type" => "function",
                       "name" => "inspect",
                       "defer_loading" => true
                     }
                   ]
                 }
               ])

      assert {:ok, [^known]} =
               ToolContract.validate_loaded(
                 [
                   %{
                     "type" => "namespace",
                     "name" => "analysis_tools",
                     "description" => "Tools in the analysis_tools namespace.",
                     "tools" => [
                       %{
                         "type" => "function",
                         "name" => "inspect",
                         "defer_loading" => true
                       }
                     ]
                   }
                 ],
                 known: [known]
               )
    end

    test "accepts a new namespaced path beside a root name with the same flattened spelling" do
      assert {:ok, known} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "a__b"}
               ])

      assert {:ok, [%Descriptor{namespace: "a", name: "b"}]} =
               ToolContract.validate_loaded(
                 [
                   %{
                     "type" => "namespace",
                     "name" => "a",
                     "tools" => [%{"type" => "function", "name" => "b"}]
                   }
                 ],
                 known: known
               )
    end

    test "rejects a new loaded child that changes a known namespace description" do
      assert {:ok, known} =
               ToolContract.normalize([
                 %{
                   "type" => "namespace",
                   "name" => "collaboration",
                   "description" => "Team tools.",
                   "tools" => [%{"type" => "function", "name" => "spawn_agent"}]
                 }
               ])

      assert {:error,
              {:invalid_tool_contract, {:namespace_description_mismatch, "collaboration"}}} =
               ToolContract.validate_loaded(
                 [
                   %{
                     "type" => "namespace",
                     "name" => "collaboration",
                     "description" => "Different tools.",
                     "tools" => [%{"type" => "function", "name" => "send_message"}]
                   }
                 ],
                 known: known
               )
    end

    test "accepts a new valid client-owned tool list" do
      assert {:ok, [%Descriptor{name: "calendar", codec: :json}]} =
               ToolContract.validate_loaded([
                 %{
                   "type" => "function",
                   "name" => "calendar",
                   "parameters" => %{"type" => "object"}
                 }
               ])
    end
  end

  describe "decode_output/2" do
    test "uses the schema as an opaque signal to decode JSON" do
      schema = %{
        "$defs" => %{"score" => %{"type" => "number", "minimum" => 0}},
        "$ref" => "#/$defs/score"
      }

      assert {:ok, [descriptor]} =
               ToolContract.normalize([
                 %{
                   "type" => "function",
                   "name" => "structured",
                   "output_schema" => schema
                 }
               ])

      assert {:ok, %{"score" => "the tool owner validates this value"}} =
               ToolContract.decode_output(
                 descriptor,
                 ~s({"score":"the tool owner validates this value"})
               )
    end

    test "rejects invalid JSON when a schema declares structured output" do
      assert {:ok, [descriptor]} =
               ToolContract.normalize([
                 %{
                   "type" => "custom",
                   "name" => "structured",
                   "format" => %{"type" => "text"},
                   "output_schema" => %{"type" => "object"}
                 }
               ])

      assert {:error, {:invalid_tool_output_json, "structured", _reason}} =
               ToolContract.decode_output(descriptor, "not-json")
    end

    test "keeps undeclared JSON-looking output as text" do
      assert {:ok, [descriptor]} =
               ToolContract.normalize([
                 %{"type" => "function", "name" => "text-result"}
               ])

      assert {:ok, ~s({"value":1})} = ToolContract.decode_output(descriptor, ~s({"value":1}))
    end
  end
end
