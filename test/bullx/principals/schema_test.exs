defmodule BullX.Principals.SchemaTest do
  use BullX.DataCase, async: false

  alias BullX.Principals
  alias BullX.Principals.Agent

  test "create_human stores a lowercase uid and normalized contact fields" do
    assert {:ok, %{principal: principal, human_user: human_user}} =
             Principals.create_human(%{
               uid: " Alice ",
               display_name: "Alice",
               email: " ALICE@Example.COM ",
               phone: "+14155552671"
             })

    assert principal.uid == "alice"
    assert principal.type == :human
    assert principal.status == :active
    assert human_user.email == "alice@example.com"
    assert human_user.phone == "+14155552671"
  end

  test "create_agent validates agentic_loop profile and exposes LLM fallbacks" do
    assert {:ok, %{principal: principal, agent: agent}} =
             Principals.create_agent(%{
               uid: "research-agent",
               display_name: "Research Agent",
               profile: %{
                 main_llm: "llm.primary",
                 goals: "Track market shifts",
                 soul: "Careful and concise"
               }
             })

    assert principal.type == :agent
    assert agent.type == :agentic_loop
    assert Agent.main_llm(agent) == "llm.primary"
    assert Agent.compression_llm(agent) == "llm.primary"
    assert Agent.heavy_llm(agent) == "llm.primary"

    assert {:error, changeset} =
             Principals.create_agent(%{
               uid: "broken-agent",
               profile: %{main_llm: "llm.primary"}
             })

    assert %{profile: [_ | _]} = errors_on(changeset)
  end
end
