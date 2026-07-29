defmodule Ankole.AIGateway.CodexModelsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CodexModels

  # Field set from the codex pin's own minimal deserialize test
  # (`model_info_defaults_availability_nux_to_none_when_omitted`,
  # rust-v0.146.0 codex-rs/protocol/src/openai_models.rs). Every field
  # listed there is required by serde on the pinned version.
  @required_card_fields ~w(
    slug display_name description supported_reasoning_levels shell_type
    visibility supported_in_api priority upgrade base_instructions
    support_verbosity default_verbosity apply_patch_tool_type
    truncation_policy supports_parallel_tool_calls experimental_supported_tools
  )

  test "codex_manifest_request? keys on the client_version query parameter" do
    assert CodexModels.codex_manifest_request?(%{"client_version" => "0.146.0"})
    refute CodexModels.codex_manifest_request?(%{})
    refute CodexModels.codex_manifest_request?(%{"q" => "gpt"})
  end

  test "card carries every serde-required field of the pinned ModelInfo" do
    card = CodexModels.card("gpt-main")

    for field <- @required_card_fields do
      assert Map.has_key?(card, field), "missing required card field #{field}"
    end
  end

  test "card reproduces the codex fallback baseline and opens the search gate" do
    card = CodexModels.card("gpt-main")

    assert card["slug"] == "gpt-main"
    assert card["display_name"] == "gpt-main"
    assert card["shell_type"] == "default"
    assert card["visibility"] == "none"
    assert card["truncation_policy"] == %{"mode" => "bytes", "limit" => 10_000}
    assert card["context_window"] == 272_000
    assert card["input_modalities"] == ["text", "image"]
    assert card["supports_search_tool"] == true
    assert card["apply_patch_tool_type"] == "freeform"
    assert card["use_responses_lite"] == false
    assert is_binary(card["base_instructions"])
    assert byte_size(card["base_instructions"]) > 10_000
  end

  test "cards follow the pinned Codex responses-lite model set" do
    for slug <- ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna) do
      assert CodexModels.card(slug)["use_responses_lite"]
    end

    refute CodexModels.card("gpt-5.5")["use_responses_lite"]
  end

  test "cards serialize to JSON without atoms or structs" do
    assert {:ok, encoded} = Ankole.JSON.encode(CodexModels.card("gpt-main"))
    assert encoded =~ "supports_search_tool"
  end
end
