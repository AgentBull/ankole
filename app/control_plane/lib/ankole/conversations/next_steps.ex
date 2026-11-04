defmodule Ankole.Conversations.NextSteps do
  @moduledoc """
  The personal assistant's next-step menu on a Human's chat home.

  A menu offers 4 to 7 concrete next steps, with at most one ambitious step.
  The personal assistant's `light` model profile writes it from what the Human
  can already see: recent conversations, recently updated pages, and recent
  Brain knowledge. The chat home reuses the latest menu until it is a day old,
  until every step in it has been chosen, or until the Human asks for another
  menu. A step that two menus offered without being chosen is not offered
  again, and neither is a chosen step.
  """

  require Ash.Query
  require Logger

  alias Ankole.{AIGateway, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations.{NativeRoom, NextStep}
  alias Ankole.Pod.Pages

  @menu_hours 24
  @min_steps 4
  @max_steps 7
  @retention_days 30
  @limits %{"title" => 120, "outcome" => 300, "effort" => 80, "why_now" => 300}

  @doc """
  Returns the open steps of the Human's current menu, writing a new menu when
  the current one is missing, a day old, fully chosen, or `refresh: true` asks
  for another. A Human without a personal assistant gets no menu. When a new
  menu cannot be written, the Human keeps a current menu that is less than a
  day old and otherwise gets none.
  """
  @spec menu(Actor.t(), keyword()) :: [NextStep.t()]
  def menu(%Actor{} = actor, opts \\ []) do
    uid = Actor.uid(actor)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Ankole.Principals.personal_assistant(uid) do
      %{uid: assistant_uid} ->
        latest = latest_menu(uid)

        if Keyword.get(opts, :refresh, false) or expired?(latest, now) or open(latest) == [] do
          write_menu(actor, assistant_uid, latest, now, Keyword.get(opts, :locale))
        else
          open(latest)
        end

      nil ->
        []
    end
  end

  @doc "Records that the Human chose one of their own offered steps."
  @spec choose(Actor.t(), String.t()) :: :ok | {:error, :not_found}
  def choose(%Actor{} = actor, id) when is_binary(id) do
    uid = Actor.uid(actor)

    case NextStep
         |> Ash.Query.filter(id == ^id and human_uid == ^uid)
         |> Ankole.Ash.read_one!() do
      %NextStep{chosen_at: nil} = step ->
        {:ok, _} = Ankole.Ash.update(step, :choose, %{chosen_at: DateTime.utc_now()})
        :ok

      %NextStep{} ->
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  defp latest_menu(uid) do
    NextStep
    |> Ash.Query.filter(human_uid == ^uid)
    |> Ash.Query.sort(last_offered_at: :desc)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read!()
    |> case do
      [] ->
        []

      [%NextStep{last_offered_at: offered_at}] ->
        NextStep
        |> Ash.Query.filter(human_uid == ^uid and last_offered_at == ^offered_at)
        |> Ash.Query.sort(position: :asc)
        |> Ankole.Ash.read!()
    end
  end

  defp open(menu), do: Enum.filter(menu, &is_nil(&1.chosen_at))

  defp expired?([], _now), do: true

  defp expired?([%NextStep{last_offered_at: offered_at} | _], now),
    do: DateTime.diff(now, offered_at, :hour) >= @menu_hours

  defp write_menu(actor, assistant_uid, latest, now, locale) do
    # Only the latest menu's open steps can appear once more. Every step that two
    # menus offered without a choice stays retired until retention removes it.
    repeatable = latest |> open() |> Enum.filter(&(&1.offer_count < 2))

    with {:ok, steps} <- propose(actor, assistant_uid, repeatable, locale),
         {:ok, menu} <- commit(Actor.uid(actor), steps, repeatable, latest, now) do
      menu
    else
      {:error, reason} ->
        Logger.info("next-step menu was not written: #{inspect(reason)}")
        if expired?(latest, now), do: [], else: open(latest)
    end
  end

  defp propose(actor, assistant_uid, repeatable, locale) do
    request = %{
      "model" => "light",
      "instructions" => instructions(locale),
      "input" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => context(actor, repeatable)}
          ]
        }
      ],
      "max_output_tokens" => 2_000,
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "pod_next_steps",
          "strict" => true,
          "schema" => schema()
        }
      }
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(assistant_uid, request,
             subject_type: "agent",
             caller: "next_steps"
           ),
         {:ok, text} <- AIGateway.completed_output_text(body),
         {:ok, %{"steps" => steps}} when is_list(steps) <- Ankole.JSON.decode(text) do
      validate(steps)
    else
      {:ok, _other} -> {:error, :invalid_next_steps}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # The server owns the menu contract, so the model's reply is normalized here:
  # fields are trimmed and bounded, only the first ambitious step keeps its flag,
  # and a reply with too few complete steps writes no menu.
  def validate(steps) do
    normalized =
      steps
      |> Enum.take(@max_steps)
      |> Enum.flat_map(&normalize_step/1)
      |> keep_first_ambitious()

    if length(normalized) >= @min_steps,
      do: {:ok, normalized},
      else: {:error, :insufficient_next_steps}
  end

  defp normalize_step(%{} = step) do
    fields =
      Map.new(@limits, fn {key, limit} ->
        {key, step[key] |> to_text() |> String.slice(0, limit) |> String.trim()}
      end)

    if Enum.any?(fields, fn {_key, value} -> value == "" end) do
      []
    else
      [
        fields
        |> Map.put("ambitious", step["ambitious"] == true)
        |> Map.put("repeat_of", if(is_binary(step["repeat_of"]), do: step["repeat_of"]))
      ]
    end
  end

  defp normalize_step(_step), do: []

  defp to_text(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp to_text(_value), do: ""

  defp keep_first_ambitious(steps) do
    {steps, _seen} =
      Enum.map_reduce(steps, false, fn step, seen ->
        ambitious = step["ambitious"] and not seen
        {%{step | "ambitious" => ambitious}, seen or ambitious}
      end)

    steps
  end

  defp commit(uid, steps, repeatable, previous, now) do
    previous_at =
      case previous do
        [%NextStep{last_offered_at: at} | _] -> at
        [] -> nil
      end

    Repo.transact_top_level(fn ->
      Ankole.AdvisoryLock.lock!(Repo, "next-steps:#{Repo.tenant_id!()}:#{uid}")

      # Another request may have written a menu while the model was answering.
      case latest_menu(uid) do
        [%NextStep{last_offered_at: at} | _] = current when at != previous_at ->
          {:ok, open(current)}

        _unchanged ->
          prune(uid, now)
          {:ok, write_steps(uid, steps, Map.new(repeatable, &{&1.id, &1}), now)}
      end
    end)
  end

  defp write_steps(uid, steps, repeatable, now) do
    {written, _used} =
      steps
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {step, position}, used ->
        attrs = %{
          title: step["title"],
          outcome: step["outcome"],
          effort: step["effort"],
          why_now: step["why_now"],
          ambitious: step["ambitious"],
          position: position,
          last_offered_at: now
        }

        case Map.get(repeatable, step["repeat_of"]) do
          %NextStep{id: id} = earlier ->
            if MapSet.member?(used, id) do
              {offer(uid, attrs), used}
            else
              {:ok, step} =
                Ankole.Ash.update(earlier, :reoffer, Map.put(attrs, :offer_count, 2))

              {step, MapSet.put(used, id)}
            end

          nil ->
            {offer(uid, attrs), used}
        end
      end)

    written
  end

  defp offer(uid, attrs) do
    Ankole.Ash.create!(
      NextStep,
      :offer,
      attrs |> Map.put(:human_uid, uid) |> Map.put(:offer_count, 1)
    )
  end

  defp prune(uid, now) do
    cutoff = DateTime.add(now, -@retention_days, :day)

    NextStep
    |> Ash.Query.filter(human_uid == ^uid and last_offered_at < ^cutoff)
    |> Ankole.Ash.destroy_where(:destroy)

    :ok
  end

  defp instructions(locale) do
    language =
      if is_binary(locale) and locale != "",
        do: "Write every field in the language of the locale #{locale}.",
        else: "Write every field in the language that the context mostly uses."

    """
    You are the Human's personal assistant in an Ankole workspace. Propose the
    next steps that the Human could start with you right now.

    - Offer 4 to 7 steps, recommended step first. Each step must be concrete and
      ready to start: the title is a short instruction the Human could send you.
    - Ground every step in the context below. Never invent projects, people,
      data or deadlines that the context does not show.
    - `outcome` says what the Human gets, `effort` how long the work takes,
      and `why_now` why the step matters now, naming the conversation or page
      it comes from.
    - At most one step may be ambitious: a step that breaks routine and could
      change results by an order of magnitude. Mark it with `ambitious` and
      base it on a specific item from the context; otherwise leave it out.
    - When a step repeats one from the previous menu, set `repeat_of` to that
      step's id; otherwise set it to null. Never repeat the steps listed as
      chosen or retired.
    - When the context supports fewer than 4 grounded steps, return no steps.
    - #{language}
    """
  end

  defp context(actor, repeatable) do
    uid = Actor.uid(actor)

    [
      section("Conversations that need the Human", attention_rooms(actor)),
      section("Recent conversations, newest first", recent_rooms(actor)),
      section("Recently updated pages the Human can open", recent_pages(actor, :pages)),
      section("Recent Brain knowledge", recent_pages(actor, :brain)),
      section(
        "Steps from the previous menu that may be offered once more",
        Enum.map(repeatable, &"id=#{&1.id} | #{&1.title} | #{&1.outcome}")
      ),
      section("Retired steps: do not offer these again", avoided_titles(uid, :retired)),
      section("Chosen steps: do not offer these again", avoided_titles(uid, :chosen))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> "The workspace has no recent activity yet."
      text -> text
    end
  end

  defp section(_title, []), do: nil
  defp section(title, lines), do: title <> ":\n" <> Enum.map_join(lines, "\n", &("- " <> &1))

  defp attention_rooms(actor) do
    actor
    |> NativeRoom.list(attention: true, order: :recent)
    |> Enum.take(8)
    |> Enum.map(&room_line/1)
  end

  defp recent_rooms(actor) do
    actor
    |> NativeRoom.list(order: :recent, limit: 12)
    |> Enum.map(&room_line/1)
  end

  defp room_line(detail) do
    title =
      case String.trim(detail.conversation.title || "") do
        "" -> detail.agents |> Enum.map_join(", ", &NativeRoom.display_name/1)
        title -> title
      end

    case String.trim(detail[:latest_message_preview] || "") do
      "" -> title
      preview -> "#{title}: #{String.slice(preview, 0, 160)}"
    end
  end

  defp recent_pages(actor, domain) do
    case Pages.list(actor, %{domain: domain}) do
      {:ok, pages} ->
        pages
        |> Enum.filter(&(is_nil(&1.system_key) and String.trim(&1.title || "") != ""))
        |> Enum.take(if(domain == :brain, do: 10, else: 15))
        |> Enum.map(
          &"#{&1.type}: #{&1.title} (updated #{Calendar.strftime(&1.updated_at, "%Y-%m-%d")})"
        )

      {:error, _reason} ->
        []
    end
  end

  defp avoided_titles(uid, :chosen) do
    NextStep
    |> Ash.Query.filter(human_uid == ^uid and not is_nil(chosen_at))
    |> Ash.Query.sort(chosen_at: :desc)
    |> avoided()
  end

  defp avoided_titles(uid, :retired) do
    NextStep
    |> Ash.Query.filter(human_uid == ^uid and is_nil(chosen_at) and offer_count >= 2)
    |> Ash.Query.sort(last_offered_at: :desc)
    |> avoided()
  end

  defp avoided(query),
    do: query |> Ash.Query.limit(20) |> Ankole.Ash.read!() |> Enum.map(& &1.title)

  defp schema do
    text = %{"type" => "string"}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["steps"],
      "properties" => %{
        "steps" => %{
          "type" => "array",
          "maxItems" => @max_steps,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["title", "outcome", "effort", "why_now", "ambitious", "repeat_of"],
            "properties" => %{
              "title" => text,
              "outcome" => text,
              "effort" => text,
              "why_now" => text,
              "ambitious" => %{"type" => "boolean"},
              "repeat_of" => %{"type" => ["string", "null"]}
            }
          }
        }
      }
    }
  end
end
