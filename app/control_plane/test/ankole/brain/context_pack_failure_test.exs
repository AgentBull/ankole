defmodule Ankole.Brain.ContextPackFailureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.Brain.ContextPack

  setup do
    # Do not borrow a shared owner left by the previous serial case.
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
  end

  test "database failures keep injection best effort and emit safe call-site diagnostics" do
    tenant_id = Ankole.Ecto.UUIDv7.autogenerate()
    agent_uid = Ankole.Ecto.UUIDv7.autogenerate()
    text = "private-message-must-not-enter-diagnostics"

    # No Sandbox checkout: these production reads reach the real Repo failure.
    log =
      capture_log(
        [format: "$metadata$message\n", metadata: [:event, :failure, :stacktrace]],
        fn ->
          Ankole.Repo.with_tenant(tenant_id, fn ->
            assert ContextPack.context_pack(agent_uid, %{recent_text: text}) == %{
                     entities: [],
                     open_threads: []
                   }

            assert ContextPack.volunteer_pointers(agent_uid, text) == []
          end)
        end
      )

    assert log =~ "brain.context_pack.failed"
    assert log =~ "brain.volunteer_pointers.failed"
    assert log =~ "context_pack.ex:"
    refute log =~ text
  end
end
