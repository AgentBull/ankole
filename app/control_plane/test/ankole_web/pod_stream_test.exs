defmodule AnkoleWeb.PodStreamTest do
  use ExUnit.Case, async: true
  alias AnkoleWeb.PodStream

  test "unavailable reads clear stale labels and preserve the revision watermark" do
    active = %{epoch: 3, revision: 7, state: "active", phase: %{"label" => "Reading"}, tools: []}
    unavailable = %{active | state: "unavailable", revision: 0, phase: nil}

    assert {%{state: "unavailable", revision: 7} = cleared, true} =
             PodStream.merge_activity(active, unavailable)

    assert {^cleared, false} = PodStream.merge_activity(cleared, active)
    assert {^active, true} = PodStream.merge_activity(cleared, active, true)

    assert {%{state: "active", revision: 8}, true} =
             PodStream.merge_activity(cleared, %{active | revision: 8})

    assert {%{epoch: 3, state: "unavailable", revision: 7}, true} =
             PodStream.merge_activity(active, %{unavailable | epoch: 0})

    assert {^active, false} = PodStream.merge_activity(active, %{unavailable | epoch: 2})
  end
end
