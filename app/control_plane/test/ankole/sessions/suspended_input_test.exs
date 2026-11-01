defmodule Ankole.Sessions.SuspendedInputTest do
  use Ankole.SessionsCase
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Notices
  alias Ankole.Sessions.Run

  test "a queued addressed input completes once with a localized durable notice" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{signal: input}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "hello", explicit: true}),
               now: @base_time
             )

    suspend_tenant()

    assert {:ok, %{status: :tenant_suspended, posted: %{intents: [notice]}, notice_error: nil}} =
             Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, input)

    assert notice.outbound_key == "ai-tenant-suspended:#{input.id}"

    assert notice.payload["text"] ==
             Ankole.I18n.t("conversations.delivery.reply.tenant_suspended", %{"ref" => input.id})

    assert notice.payload["reply_presentation"]["answer"] == notice.payload["text"]

    assert %{completed_at: %DateTime{}, last_attempt_at: nil, attempt_count: 0} =
             Repo.reload!(input)

    refute Repo.get_by(Conversation, subject_uid: agent.uid)
    assert Repo.get_by!(AgentWorker, agent_uid: agent.uid).state == :absent

    assert {:ok, %{status: :unchanged}} =
             Notices.finalize({:error, :tenant_suspended}, input, DateTime.utc_now(:microsecond))

    assert Repo.aggregate(
             from(o in Intent, where: o.source_signal_id == ^input.id),
             :count
           ) == 1
  end

  test "a suspended inbox rejects unstarted input but preserves an admitted attempt" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{signal: input}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "hello", explicit: true}),
               now: @base_time
             )

    assert {:ok, %Run{}} =
             Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, input)

    admitted = Repo.reload!(input)
    suspend_tenant()
    assert {:ok, ^admitted} = Admission.authorize_event(admitted)

    assert {:ok, %Run{}} =
             Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, admitted)

    refute Repo.reload!(input).completed_at
    refute Repo.get_by(Intent, source_signal_id: input.id)
  end

  test "inbox authorization closes new input and emits its notice without creating a conversation" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{signal: input}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "queued", explicit: true}),
               now: @base_time
             )

    suspend_tenant()

    assert {:ok, %{completed_at: %DateTime{}, last_attempt_at: nil}} =
             Admission.authorize_event(input)

    assert Repo.get_by(Intent, source_signal_id: input.id)
    refute Repo.get_by(Conversation, subject_uid: agent.uid)
  end

  defp suspend_tenant do
    Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end
end
