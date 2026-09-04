defmodule Ankole.AIGateway.CodexModelsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CodexModels

  # Field set from the codex pin's own minimal deserialize test
  # (`model_info_defaults_availability_nux_to_none_when_omitted`,
  # rust-v0.153.2 codex-rs/protocol/src/openai_models.rs). Every field
  # listed there is required by serde on the pinned version.
  @required_card_fields ~w(
    slug display_name description supported_reasoning_levels shell_type
    visibility supported_in_api priority upgrade base_instructions model_messages
    support_verbosity default_verbosity apply_patch_tool_type
    truncation_policy experimental_supported_tools
  )

  test "codex_manifest_request? keys on the client_version query parameter" do
    assert CodexModels.codex_manifest_request?(%{"client_version" => "0.153.2"})
    refute CodexModels.codex_manifest_request?(%{})
    refute CodexModels.codex_manifest_request?(%{"q" => "gpt"})
  end

  test "card carries every serde-required field of the pinned ModelInfo" do
    card = CodexModels.card("gpt-main", ["text"])

    for field <- @required_card_fields do
      assert Map.has_key?(card, field), "missing required card field #{field}"
    end
  end

  test "card declares the pinned baseline and the AIGateway output contract" do
    card = CodexModels.card("gpt-main", ["text", "image"])

    assert card["slug"] == "gpt-main"
    assert card["display_name"] == "gpt-main"
    assert card["shell_type"] == "unified_exec"
    assert card["visibility"] == "none"
    assert card["truncation_policy"] == %{"mode" => "tokens", "limit" => 10_000}
    assert card["context_window"] == 272_000
    assert card["input_modalities"] == ["text", "image"]
    assert card["supports_search_tool"] == true
    assert card["apply_patch_tool_type"] == "freeform"
    assert card["use_responses_lite"] == false

    assert card["model_messages"] == %{
             "instructions_template" => card["base_instructions"],
             "instructions_variables" => nil
           }

    refute card["include_skills_usage_instructions"]
    refute card["include_plugin_usage_instructions"]
    refute card["include_apps_usage_instructions"]
    assert is_binary(card["base_instructions"])
    assert byte_size(card["base_instructions"]) > 10_000

    assert card["base_instructions"] =~
             "Model-visible tool output is limited to 10000 tokens."
  end

  test "cards keep the configured search tool on standard Responses" do
    for slug <- ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna) do
      refute CodexModels.card(slug, ["text"])["use_responses_lite"]
    end

    refute CodexModels.card("gpt-5.5", ["text"])["use_responses_lite"]
  end

  test "cards serialize to JSON without atoms or structs" do
    assert {:ok, encoded} = Ankole.JSON.encode(CodexModels.card("gpt-main", ["text"]))
    assert encoded =~ "supports_search_tool"
  end

  test "cards advertise only effective Codex input modalities" do
    assert CodexModels.card("text-only", ["text", "pdf"])["input_modalities"] == ["text"]

    assert CodexModels.card("vision", ["text", "image", "pdf"])["input_modalities"] == [
             "text",
             "image"
           ]
  end
end
