defmodule Ankole.Brain.GetPageTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.BrainFixtures
  alias Ankole.Brain.GetPage

  test "Pod and entity reads share lightweight projections and complete full content" do
    %{principal: human} = human_fixture()
    intro = String.duplicate("供应商报价需要注明运输条款。", 1_000)

    {:ok, parent} =
      page_fixture_result(
        %{
          slug: "companies/quotation",
          title: "Quotation",
          body: intro <> "\n\n## Conditions\n\nOnly for orders of 100 units.",
          meta: %{
            "summary" => String.duplicate("Supplier overview. ", 300),
            "internal_notes" => String.duplicate("Full detail. ", 500)
          }
        },
        human.uid
      )

    {:ok, child} =
      page_fixture_result(
        %{slug: "companies/quotation/shipping", title: "Shipping", body: "Freight terms."},
        human.uid
      )

    actor = actor_fixture(human)
    context = %{querier_uid: human.uid, disclosure: Ankole.Brain.Access.open_disclosure()}

    for {brain_level, pod_level} <- [{:l0, "L0"}, {:l1, "L1"}, {:l2, "L2"}] do
      assert {:ok, entity} = GetPage.get_page(human.uid, parent.id, level: brain_level)
      assert {:ok, pod} = Ankole.Pod.AgentPages.read(actor, context, parent.id, pod_level)
      assert entity.revision == pod.revision
      assert entity.summary == pod.summary
      assert Ankole.Kernel.estimate_o200k_base_tokens(pod.summary) <= 100

      case brain_level do
        :l0 ->
          for field <- [:children, :metadata, :facts, :takes, :content, :body] do
            refute Map.has_key?(entity, field)
            refute Map.has_key?(pod, field)
          end

        :l1 ->
          assert entity.content == pod.body
          assert pod.body =~ "Introduction shortened"
          assert pod.body =~ "## Conditions"
          refute pod.body =~ "Only for orders"
          refute pod.body =~ "internal_notes"
          refute Map.has_key?(pod, :metadata)
          refute Map.has_key?(entity, :metadata)
          refute Map.has_key?(entity, :rendered)
          assert Enum.map(pod.children, & &1.id) == [child.id]
          assert Enum.map(entity.children, & &1.id) == [child.id]
          assert Map.has_key?(entity, :facts)

        :l2 ->
          assert entity.content == pod.body
          assert pod.body =~ intro
          assert pod.body =~ "Only for orders of 100 units."
          assert pod.metadata == parent.meta
      end
    end
  end

  test "full parent reads keep children as summaries and expose clean business metadata" do
    %{principal: human} = human_fixture()

    {:ok, parent} =
      page_fixture_result(
        %{
          slug: "companies/acme",
          title: "Acme",
          body: "Parent body.",
          meta: %{"summary" => "Customer"}
        },
        human.uid
      )

    {:ok, child} =
      page_fixture_result(
        %{
          slug: "companies/acme/account",
          title: "Account",
          body: "Long account details.",
          meta: %{"summary" => "Account overview"}
        },
        human.uid
      )

    assert {:ok, page} = GetPage.get_page(human.uid, parent.id, level: :l2)
    assert page.content =~ "Parent body"
    refute page.content =~ "Long account details"
    assert [%{id: id, summary: "Account overview"}] = page.children
    assert id == child.id
    assert page.metadata["summary"] == "Customer"
    refute Map.has_key?(page.metadata, "upstream_state")
    assert page.scorecard == %{takes: 0, brier: nil}
  end

  test "overview retains short code and full reads preserve its exact bytes" do
    %{principal: human} = human_fixture()

    {:ok, page} =
      page_fixture_result(
        %{slug: "notes/code", title: "Code", body: "# Example\n\n```sh\necho source-bytes\n```"},
        human.uid
      )

    assert {:ok, full} = GetPage.get_page(human.uid, page.id, level: :l2)
    assert full.content =~ "echo source-bytes"
    assert {:ok, overview} = GetPage.get_page(human.uid, page.id, level: :l1)
    assert overview.content =~ "echo source-bytes"
  end
end
