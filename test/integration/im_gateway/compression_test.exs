defmodule BullX.Integration.IMGateway.CompressionTest do
  @moduledoc """
  Family E — conversation compression / summary.

  Covers explicit `/compress`, provider context-overflow auto-compression, and
  the key invariant that editing a message *before* the last summary does not
  affect the agent (the raw message is folded behind the summary).

  Uses large user messages so the compressible interval is non-empty (a single
  oversized message is delivered as one batch — see family A — so it is not
  split by the coalesce char limit).
  """
  use BullX.Integration.IMGateway.Case

  @long String.duplicate("compressible context ", 900)

  # Queue mode (no responder) so the exact LLM call sequence is scripted.

  test "E-compress: /compress over real history writes a summary" do
    chat = new_dm(with: :alice)

    MockLLM.push_text("first answer")
    say(chat, :alice, @long <> " topic one")
    settle()

    MockLLM.push_text("second answer")
    say(chat, :alice, @long <> " topic two")
    settle()

    MockLLM.push_text("a compressed summary of the conversation")
    command(chat, :alice, "/compress")
    settle()

    assert Repo.exists?(from(m in Message, where: m.kind == :summary))
  end

  test "E1: a provider context-overflow triggers compression then retries the answer" do
    chat = new_dm(with: :alice)

    MockLLM.push_text("first answer")
    say(chat, :alice, @long <> " opening")
    settle()

    MockLLM.push_text("second answer")
    say(chat, :alice, @long <> " continued")
    settle()

    # Third turn: the model reports context overflow, the agent compresses, then
    # retries and succeeds.
    MockLLM.push_error(overflow_error())
    MockLLM.push_text("summary after overflow")
    MockLLM.push_text("answer after compression")
    say(chat, :alice, "third message")
    settle()

    assert last_bot_text(chat) == "answer after compression"

    assert %Message{metadata: %{"trigger" => "provider_context_overflow"}} =
             Repo.one(from(m in Message, where: m.kind == :summary, limit: 1))
  end

  test "B5: editing a message before the last summary does not affect the agent" do
    chat = new_dm(with: :alice)

    MockLLM.push_text("answer one")
    first = say(chat, :alice, @long <> " SECRETALPHA")
    settle()

    MockLLM.push_text("answer two")
    say(chat, :alice, @long <> " topic beta")
    settle()

    MockLLM.push_text("compressed summary text")
    command(chat, :alice, "/compress")
    settle()
    assert Repo.exists?(from(m in Message, where: m.kind == :summary))

    calls_before = MockLLM.call_count()

    # Edit a pre-summary (now folded) message.
    edit(first, "tiny EDITEDALPHA")
    settle()

    # The folded edit triggers no new generation.
    assert MockLLM.call_count() == calls_before

    # A subsequent turn renders the summary, not the edited raw message.
    MockLLM.push_text("answer three")
    say(chat, :alice, "continue please")
    settle()

    prompt = MockLLM.last_prompt_text()
    assert prompt =~ "compressed summary text"
    refute prompt =~ "EDITEDALPHA"
  end

  defp overflow_error do
    ReqLLM.Error.API.Request.exception(
      reason: "context length exceeded",
      status: 400,
      response_body: %{
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "input token count exceeds the maximum number of input tokens"
        }
      }
    )
  end
end
