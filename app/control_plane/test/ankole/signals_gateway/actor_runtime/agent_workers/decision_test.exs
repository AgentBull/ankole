defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.DecisionTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Decision

  @now ~U[2026-10-03 12:00:00.000000Z]
  @target %{image: "worker:2", protocol_version: 7, settings_digest: "template-a"}
  @minute 60_000

  test "a Secret without an observed Pod cannot settle the current generation" do
    object = %{generation: "gen-a", phase: :exited, instance_present?: false}

    for state <- ["starting", "deleting"] do
      facts = facts(worker: %{state: state, instance_seen_at: nil}) |> Map.put(:objects, [object])
      assert :create = Decision.next(facts)

      assert {:delete_object, ^object} =
               Decision.next(put_in(facts.worker.instance_seen_at, ago(@minute)))
    end
  end

  describe "a Worker that is not there" do
    test "is created when a path wants it or a Turn is live" do
      assert :begin_create = next(worker: %{state: "absent"}, wanted: true)
      assert :begin_create = next(worker: %{state: "absent"}, turn_in_progress?: true)
      assert :none = next(worker: %{state: "absent"})
    end

    test "is not created for an Agent that is not active" do
      assert :none = next(worker: %{state: "absent"}, wanted: true, agent: :disabled)
    end
  end

  describe "a running Worker" do
    test "is adopted when its object runs" do
      assert :none = next(worker: ready(), object: :running)
    end

    test "never stops for idleness when the release time is never" do
      assert :none = next(worker: ready(idle_for_ms: 365 * 24 * 3_600_000), object: :running)
    end

    test "stops after the release time when every idle condition holds" do
      settings = %{idle_release_after_ms: 15 * @minute}
      idle = ready(idle_for_ms: 15 * @minute)

      assert {:release, "idle_release"} = next(worker: idle, object: :running, settings: settings)

      for {overrides, reason} <- [
            {[worker: ready(idle_for_ms: 14 * @minute)], "idle time too short"},
            {[worker: ready(idle_for_ms: 15 * @minute, active_tasks: 1)], "a task runs"},
            {[worker: Map.put(idle, :last_worker_heartbeat_at, ago(31_000))], "old heartbeat"},
            {[turn_in_progress?: true], "a Turn is in progress"},
            {[wanted: true], "a path wants it"}
          ] do
        facts = Keyword.merge([worker: idle, object: :running, settings: settings], overrides)
        assert next(facts) == :none, reason
      end
    end

    test "of a disabled Agent stops when it has no live Turn and no task" do
      assert {:release, "agent_inactive"} =
               next(worker: ready(), object: :running, agent: :disabled)

      assert :none =
               next(worker: ready(), object: :running, agent: :disabled, turn_in_progress?: true)

      assert :none =
               next(worker: ready(active_tasks: 1), object: :running, agent: :disabled)
    end

    test "that starts and is no longer wanted stops at once" do
      starting = %{state: "starting", state_changed_at: ago(5_000)}

      assert {:release, "not_needed"} = next(worker: starting, object: :starting)
      assert :create = next(worker: starting, object: :starting, wanted: true)

      # PAW 4.7: an instance that never joined is deleted, not paused, also
      # when the Agent is disabled.
      assert {:release, "not_needed"} =
               next(worker: starting, object: :starting, wanted: true, agent: :disabled)
    end

    test "that went stale stays while its last idle time is below the release time" do
      stale = %{
        ready(idle_for_ms: 0)
        | state: "stale",
          transport_route: nil,
          state_changed_at: ago(5_000)
      }

      # A control-plane restart makes every Worker stale for a moment.
      assert :none = next(worker: stale, object: :running)

      assert :none =
               next(
                 worker: stale,
                 object: :running,
                 settings: %{idle_release_after_ms: 15 * @minute}
               )

      long_idle = %{stale | load: %{"active_tasks" => 0, "idle_for_ms" => 16 * @minute}}

      assert {:release, "not_needed"} =
               next(
                 worker: long_idle,
                 object: :running,
                 settings: %{idle_release_after_ms: 15 * @minute}
               )
    end

    test "that went stale stops for a disabled Agent once no Turn is live" do
      assert {:release, "agent_inactive"} =
               next(worker: stale(), object: :running, agent: :disabled)

      assert :none =
               next(worker: stale(), object: :running, agent: :disabled, turn_in_progress?: true)
    end

    test "that starts waits for its join while its object runs" do
      starting = %{state: "starting", state_changed_at: ago(5_000)}

      assert {:wait, _} = next(worker: starting, object: :running, wanted: true)
    end
  end

  describe "a Worker that differs from this node" do
    test "is replaced at once on another protocol, even with work" do
      busy = ready(active_tasks: 2, protocol_version: 6)

      assert {:replace, "replacement", :now} =
               next(worker: busy, object: :running, turn_in_progress?: true)
    end

    test "is replaced only when idle on another image or settings" do
      for worker <- [ready(image: "worker:1"), ready(settings_digest: "template-old")] do
        assert {:replace, "replacement", :graceful} = next(worker: worker, object: :running)

        assert :none =
                 next(worker: %{worker | load: %{"active_tasks" => 1}}, object: :running)

        assert :none = next(worker: worker, object: :running, turn_in_progress?: true)
      end
    end

    test "a changed paused instance is deleted before another generation" do
      for worker <- [
            %{state: "paused", image: "worker:1"},
            %{state: "paused", protocol_version: 6},
            %{state: "paused", settings_digest: "settings-old"}
          ] do
        assert {:replace, "replacement", :now} = next(worker: worker, object: :paused)
      end
    end
  end

  describe "the cache and the not-ready timer" do
    test "a Worker that stays not ready for the ready timeout is rebuilt" do
      for state <- ["starting", "stale"] do
        late = %{state: state, state_changed_at: ago(10 * @minute)}

        assert {:replace, "rebuild", :now} =
                 next(worker: late, object: :running, wanted: true)

        assert next(
                 worker: %{late | state_changed_at: ago(9 * @minute)},
                 object: :running,
                 wanted: true
               ) !=
                 {:replace, "rebuild", :now}
      end
    end

    test "an exited instance is deleted without restarting that generation" do
      for wanted <- [true, false] do
        assert {:replace, "exited", :now} =
                 next(worker: %{state: "starting"}, object: :exited, wanted: wanted)
      end
    end

    test "counts only the time that this control plane observed" do
      # A shutdown made the row stale an hour ago; the control plane started
      # again two minutes ago, so the Worker gets the full timeout to return.
      stale = %{ready() | state: "stale", state_changed_at: ago(60 * @minute)}

      refute next(
               worker: stale,
               object: :running,
               wanted: true,
               observing_since: ago(2 * @minute)
             ) ==
               {:replace, "rebuild", :now}

      assert {:replace, "rebuild", :now} =
               next(
                 worker: stale,
                 object: :running,
                 wanted: true,
                 observing_since: ago(10 * @minute)
               )
    end
  end

  describe "backend objects" do
    test "a same-generation extra instance is removed without replacing the committed instance" do
      selected = %{generation: "gen-a", instance_ref: "selected", phase: :running}
      extra = %{generation: "gen-a", instance_ref: "extra", phase: :running}
      facts = facts(worker: Map.put(ready(), :instance_ref, "selected"), wanted: true)

      for objects <- [[selected, extra], [extra, selected]] do
        assert {:delete_object, ^extra} = Decision.next(%{facts | objects: objects})
      end

      assert :none = Decision.next(%{facts | objects: [selected]})
    end

    test "an exited instance of a stale row is removed whether wanted or not" do
      assert {:replace, "exited", :now} = next(worker: stale(), object: :exited, wanted: true)
      assert {:replace, "exited", :now} = next(worker: stale(), object: :exited)
    end

    test "a gone object ends the generation" do
      assert :mark_absent = next(worker: stale(), object: nil)
    end

    test "a row with a connection waits until WorkerAdmission ends the connection" do
      for object <- [:exited, nil] do
        assert {:wait, _since} = next(worker: ready(), object: object, wanted: true)
        assert {:wait, _since} = next(worker: ready(), object: object)

        connected_drain = %{draining("idle_release") | transport_route: "route-a"}
        assert {:wait, _since} = next(worker: connected_drain, object: object)
      end
    end

    test "an unobserved generation is resent even after the readiness deadline" do
      for age <- [30_000, 61_000, 24 * 60 * @minute], state <- ["starting", "deleting"] do
        assert :create =
                 next(
                   worker: %{state: state, instance_seen_at: nil, state_changed_at: ago(age)},
                   wanted: true
                 )
      end
    end

    test "readiness timing starts only after the first instance observation" do
      assert {:wait, _} =
               next(
                 worker: %{
                   state: "starting",
                   instance_seen_at: ago(@minute),
                   state_changed_at: ago(60 * @minute)
                 },
                 object: :running,
                 wanted: true
               )
    end

    test "an object of another generation is deleted first" do
      facts =
        facts(worker: ready(), wanted: true)
        |> Map.put(:objects, [
          %{generation: "gen-old", phase: :running},
          %{generation: "gen-a", phase: :running}
        ])

      assert {:delete_object, %{generation: "gen-old", phase: :running}} = Decision.next(facts)
    end

    test "a deleted Agent's objects go before its row" do
      deleting = %{state: "deleting", generation: nil}

      facts =
        facts(worker: deleting, agent: :deleted)
        |> Map.put(:objects, [%{generation: "gen-a", phase: :exited}])

      assert {:delete_object, %{generation: "gen-a", phase: :exited}} = Decision.next(facts)
      assert :delete_storage = next(worker: deleting, agent: :deleted, object: nil)
    end
  end

  describe "a draining Worker" do
    test "an exited instance is deleted after idle drain" do
      assert :delete_now = next(worker: draining("idle_release"), object: :exited)
    end

    test "an exited replacement is deleted immediately" do
      assert :delete_now = next(worker: draining("replacement"), object: :exited)
    end

    test "ends its generation when the object is gone" do
      assert :mark_absent = next(worker: draining("idle_release"), object: nil)
    end

    test "waits for the stop and forces it after the grace time" do
      assert {:wait, _since} = next(worker: draining("idle_release"), object: :running)

      late = %{draining("idle_release") | state_changed_at: ago(61_000)}
      assert :delete_now = next(worker: late, object: :running)

      late_replacement = %{draining("rebuild") | state_changed_at: ago(61_000)}
      assert :delete_now = next(worker: late_replacement, object: :running)
    end
  end

  describe "pause and resume" do
    test "retries a pause until observed and clears a live route after observation" do
      for reason <- ~w(idle_release agent_inactive) do
        worker = Map.put(draining(reason), :transport_route, "route-a")
        assert :pause = next(worker: worker, object: :running, pause: true)
        assert :mark_paused = next(worker: worker, object: :paused, pause: true)

        assert :delete_now =
                 next(
                   worker: %{worker | state_changed_at: ago(61_000)},
                   object: :running,
                   pause: true
                 )
      end
    end

    test "replacement and not-needed deletion never become pauses" do
      for reason <- ~w(replacement rebuild not_needed) do
        for phase <- [:running, :paused] do
          assert {:wait, _} = next(worker: draining(reason), object: phase, pause: true)
        end
      end
    end

    test "a resume error is retried with the same process, then waits for admission" do
      worker = %{state: "paused", incarnation_id: "process-a", state_changed_at: ago(5_000)}
      assert :resume = next(worker: worker, object: :paused, wanted: true, pause: true)

      starting = %{worker | state: "starting"}
      assert :resume = next(worker: starting, object: :paused, wanted: true, pause: true)

      for phase <- [:starting, :running] do
        assert {:wait, _} = next(worker: starting, object: phase, wanted: true, pause: true)
      end
    end

    test "a paused instance is retained, recovered, or replaced from current facts" do
      worker = %{state: "paused", incarnation_id: "process-a"}
      assert :none = next(worker: worker, object: :paused, pause: true)
      assert :mark_absent = next(worker: worker, object: nil, pause: true)

      assert {:replace, "not_needed", :now} =
               next(worker: worker, object: :running, pause: true)

      assert :resume = next(worker: worker, object: :running, wanted: true, pause: true)
    end
  end

  describe "the instance lifetime" do
    test "uses the platform clock in seconds and replaces an idle instance at 90 percent" do
      facts = facts(worker: ready(), object: :running, max_instance_lifetime: 28_800)
      before = put_in(facts.objects, [%{hd(facts.objects) | started_at: ago(25_919_999)}])
      due = put_in(facts.objects, [%{hd(facts.objects) | started_at: ago(25_920_000)}])

      assert :none = Decision.next(before)
      assert {:replace, "replacement", :graceful} = Decision.next(due)
      assert :none = Decision.next(put_in(due.worker.load, %{"active_tasks" => 1}))
      assert :none = Decision.next(%{due | turn_in_progress?: true})
    end

    test "never resumes a paused instance at the lifetime boundary" do
      facts =
        facts(
          worker: %{state: "paused"},
          object: :paused,
          wanted: true,
          pause: true,
          max_instance_lifetime: 28_800
        )

      due = put_in(facts.objects, [%{hd(facts.objects) | started_at: ago(25_920_000)}])
      assert {:replace, "replacement", :now} = Decision.next(due)
    end
  end

  defp next(overrides), do: overrides |> facts() |> Decision.next()

  defp facts(overrides) do
    worker =
      Map.merge(
        %{
          state: "absent",
          generation: "gen-a",
          instance_ref: nil,
          instance_seen_at: ago(24 * 60 * @minute),
          image: @target.image,
          protocol_version: @target.protocol_version,
          settings_digest: @target.settings_digest,
          wanted_until: nil,
          incarnation_id: nil,
          transport_route: nil,
          state_changed_at: ago(@minute),
          load: %{},
          last_worker_heartbeat_at: nil,
          drain_reason: nil
        },
        Keyword.get(overrides, :worker, %{})
      )

    worker =
      if Keyword.get(overrides, :wanted, false),
        do: %{worker | wanted_until: DateTime.add(@now, 300, :second)},
        else: worker

    objects =
      case Keyword.get(overrides, :object, nil) do
        nil -> []
        phase -> [%{generation: worker.generation, phase: phase, started_at: ago(@minute)}]
      end

    %{
      worker: worker,
      agent: Keyword.get(overrides, :agent, :active),
      turn_in_progress?: Keyword.get(overrides, :turn_in_progress?, false),
      objects: objects,
      target: @target,
      definition: %{
        pause: Keyword.get(overrides, :pause, false),
        max_instance_lifetime: Keyword.get(overrides, :max_instance_lifetime)
      },
      settings:
        Map.merge(
          %{
            idle_release_after_ms: :never,
            ready_timeout_ms: 10 * @minute,
            stop_grace_ms: @minute
          },
          Keyword.get(overrides, :settings, %{})
        ),
      observing_since: Keyword.get(overrides, :observing_since, ago(24 * 60 * @minute)),
      now: @now
    }
  end

  defp ready(overrides \\ []) do
    {load, overrides} = Keyword.split(overrides, [:active_tasks, :idle_for_ms])

    Map.merge(
      %{
        state: "ready",
        transport_route: "route-a",
        state_changed_at: ago(@minute),
        last_worker_heartbeat_at: ago(5_000),
        load: %{
          "active_tasks" => Keyword.get(load, :active_tasks, 0),
          "idle_for_ms" => Keyword.get(load, :idle_for_ms, 0)
        }
      },
      Map.new(overrides)
    )
  end

  # A draining row whose connection WorkerAdmission already ended.
  defp draining(reason),
    do: %{
      state: "draining",
      drain_reason: reason,
      transport_route: nil,
      state_changed_at: ago(5_000)
    }

  defp stale, do: %{state: "stale", state_changed_at: ago(@minute)}

  defp ago(ms), do: DateTime.add(@now, -ms, :millisecond)
end
