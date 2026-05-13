defmodule BullX.LLM.SpecTest do
  use ExUnit.Case, async: true

  alias BullX.LLM.Spec

  test "parses provider id and model id from the first colon" do
    assert {:ok, %Spec{provider_id: "openai_proxy", model_id: "gpt-4.1-mini"}} =
             Spec.parse("openai_proxy:gpt-4.1-mini")

    assert {:ok, %Spec{provider_id: "bedrock", model_id: "model:with:colon"}} =
             Spec.parse("bedrock:model:with:colon")
  end

  test "rejects malformed specs" do
    assert {:error, {:invalid_llm_spec, :missing_separator}} = Spec.parse("openai_proxy")
    assert {:error, {:invalid_llm_spec, :invalid_provider_id}} = Spec.parse("OpenAI:gpt-4.1")
    assert {:error, {:invalid_llm_spec, :missing_model_id}} = Spec.parse("openai_proxy:")
    assert {:error, {:invalid_llm_spec, :not_string}} = Spec.parse(nil)
  end
end
