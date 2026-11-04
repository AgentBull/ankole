defmodule Ankole.Conversations.NextStepsTest do
  use Ankole.DataCase, async: false
  require Ash.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}
  alias Ankole.Conversations
  alias Ankole.Conversations.{NextStep, NextSteps}

  @t0 ~U[2026-11-04 09:00:00.000000Z]

  setup do
    human = human_fixture(%{display_name: "Alice"}).principal
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(human.uid)
    %{human: human, assistant: assistant, actor: actor_fixture(human.uid)}
  end

  test "the chat home keeps one menu for a day and writes the next one after it expires", ctx do
    owner = self()

    configure_model(ctx.assistant.uid, "light", fn request ->
      send(owner, {:menu_request, request.body})
      {:json, 200, response(steps(5, ambitious: 0))}
    end)

    assert [first | _] =
             menu = Conversations.next_steps(ctx.actor, now: @t0, locale: "zh-Hans-CN")

    assert Enum.map(menu, & &1.title) == Enum.map(0..4, &"Step #{&1}")
    assert first.ambitious
    refute Enum.any?(tl(menu), & &1.ambitious)
    assert_receive {:menu_request, body}
    assert body["model"] == "gpt-5.5"
    assert body["instructions"] =~ "zh-Hans-CN"

    assert Enum.map(NextSteps.menu(ctx.actor, now: DateTime.add(@t0, 23, :hour)), & &1.id) ==
             Enum.map(menu, & &1.id)

    refute_receive {:menu_request, _}

    assert [_ | _] = NextSteps.menu(ctx.actor, now: DateTime.add(@t0, 25, :hour))
    assert_receive {:menu_request, _}
  end

  test "a step offered by two menus without a choice is retired, and chosen steps leave the menu",
       ctx do
    owner = self()
    replies = Agent.start_link(fn -> [] end) |> elem(1)

    configure_model(ctx.assistant.uid, "light", fn request ->
      send(owner, {:menu_request, request.body})

      steps =
        Agent.get_and_update(replies, fn
          [next | rest] -> {next, rest}
          [] -> {steps(4), []}
        end)

      {:json, 200, response(steps)}
    end)

    [repeat, chosen | _] = NextSteps.menu(ctx.actor, now: @t0)
    assert_receive {:menu_request, _}
    assert :ok = Conversations.choose_next_step(ctx.actor, chosen.id)
    refute chosen.id in Enum.map(NextSteps.menu(ctx.actor, now: @t0), & &1.id)

    Agent.update(replies, fn _ ->
      [[step("Again", repeat_of: repeat.id) | steps(3, from: 10)]]
    end)

    assert [again | _] =
             NextSteps.menu(ctx.actor, now: DateTime.add(@t0, 1, :hour), refresh: true)

    assert_receive {:menu_request, second_request}
    assert again.id == repeat.id
    assert again.title == "Again"
    assert reload(again).offer_count == 2
    assert input_text(second_request) =~ "id=#{repeat.id}"
    assert input_text(second_request) =~ chosen.title

    # The twice-offered step stays retired in every later menu: the model sees it only as a step to avoid.
    for hours <- [2, 3] do
      assert [_ | _] =
               NextSteps.menu(ctx.actor, now: DateTime.add(@t0, hours, :hour), refresh: true)

      assert_receive {:menu_request, request}
      refute input_text(request) =~ "id=#{repeat.id}"
      assert input_text(request) =~ "Retired steps: do not offer these again:\n- Again"
    end
  end

  test "a reply with too few complete steps writes no menu", ctx do
    configure_model(ctx.assistant.uid, "light", fn _ ->
      {:json, 200, response(steps(3) ++ [step("  ", outcome: "blank title")])}
    end)

    assert [] = NextSteps.menu(ctx.actor, now: @t0)
    refute Repo.exists?(NextStep)
  end

  test "the menu uses the primary profile when the assistant has no light profile", ctx do
    owner = self()

    configure_model(ctx.assistant.uid, "primary", fn request ->
      send(owner, {:primary_request, request.body["model"]})
      {:json, 200, response(steps(4))}
    end)

    assert length(NextSteps.menu(ctx.actor, now: @t0)) == 4
    assert_receive {:primary_request, "gpt-5.5"}
  end

  test "a Human without a personal assistant gets no menu" do
    other = human_fixture(%{display_name: "Bob"}).principal
    assert [] = NextSteps.menu(actor_fixture(other.uid), now: @t0)
  end

  test "a Human can choose only their own steps", ctx do
    configure_model(ctx.assistant.uid, "light", fn _ -> {:json, 200, response(steps(4))} end)
    [step | _] = NextSteps.menu(ctx.actor, now: @t0)
    other = human_fixture(%{display_name: "Carol"}).principal

    assert {:error, :not_found} = NextSteps.choose(actor_fixture(other.uid), step.id)
    assert is_nil(reload(step).chosen_at)
  end

  test "validation bounds fields, keeps one ambitious step, and drops incomplete steps" do
    long = String.duplicate("长", 400)

    assert {:ok, [first, second, _, _]} =
             NextSteps.validate([
               %{step("A") | "title" => "  A\n  title  ", "ambitious" => true},
               %{step("B") | "outcome" => long, "ambitious" => true},
               step("C"),
               step("D"),
               %{step("E") | "effort" => ""}
             ])

    assert first["title"] == "A title"
    assert first["ambitious"]
    refute second["ambitious"]
    assert String.length(second["outcome"]) == 300
    assert {:error, :insufficient_next_steps} = NextSteps.validate([step("A"), "not a step"])
  end

  defp steps(count, opts \\ []) do
    from = Keyword.get(opts, :from, 0)
    ambitious = Keyword.get(opts, :ambitious)

    for index <- from..(from + count - 1) do
      step("Step #{index}", ambitious: index == ambitious)
    end
  end

  defp step(title, opts \\ []) do
    %{
      "title" => title,
      "outcome" => Keyword.get(opts, :outcome, "Outcome of #{title}"),
      "effort" => "10 minutes",
      "why_now" => "The Q4 plan waits for it",
      "ambitious" => Keyword.get(opts, :ambitious, false),
      "repeat_of" => Keyword.get(opts, :repeat_of)
    }
  end

  defp reload(%NextStep{id: id}),
    do: NextStep |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  defp input_text(body),
    do:
      body["input"] |> List.first() |> Map.fetch!("content") |> List.first() |> Map.fetch!("text")

  defp configure_model(agent_uid, profile, handler) do
    base_url = Ankole.AIGatewayCase.start_upstream_server(handler)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "next-steps",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, profile, %{
               provider_id: "next-steps",
               model: "gpt-5.5"
             })
  end

  defp response(steps) do
    %{
      "id" => "resp_next_steps",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => Ankole.JSON.encode!(%{"steps" => steps})}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end
end
