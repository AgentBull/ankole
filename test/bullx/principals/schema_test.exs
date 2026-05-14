defmodule BullX.Principals.SchemaTest do
  use BullX.DataCase, async: false

  alias BullX.Principals

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

  test "create_agent stores a generic Agent extension profile" do
    assert {:ok, %{principal: principal, agent: agent}} =
             Principals.create_agent(%{
               uid: "research-agent",
               display_name: "Research Agent",
               type: "research",
               profile: %{
                 "goal" => "Track market shifts"
               }
             })

    assert principal.type == :agent
    assert agent.type == "research"
    assert agent.profile == %{"goal" => "Track market shifts"}

    assert {:error, changeset} =
             Principals.create_agent(%{
               uid: "broken-agent",
               profile: %{}
             })

    assert %{type: [_ | _]} = errors_on(changeset)
  end
end
