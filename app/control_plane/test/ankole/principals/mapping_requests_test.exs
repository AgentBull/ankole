defmodule Ankole.Principals.MappingRequestsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.MappingRequests

  test "record_observation converges on one row and keeps earlier hints" do
    assert {:ok, first} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_pending",
               display_name: "Ada",
               email: "ada@example.com",
               metadata: %{"binding_name" => "lark"}
             })

    assert {:ok, second} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_pending",
               metadata: %{"channel_name" => "Ops"}
             })

    assert second.id == first.id
    assert second.display_name == "Ada"
    assert second.email == "ada@example.com"
    assert second.metadata["binding_name"] == "lark"
    assert second.metadata["channel_name"] == "Ops"
    assert [_only] = MappingRequests.list_requests()
  end

  test "concurrent observations merge after the subject lock commits" do
    provider = "lark-concurrent"
    external_id = "ou_#{System.unique_integer([:positive])}"
    parent = self()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        case Repo.get_by(MappingRequest, provider: provider, external_id: external_id) do
          nil -> :ok
          request -> Repo.delete!(request)
        end
      end)
    end)

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transact(fn _repo ->
            result =
              MappingRequests.record_observation(%{
                provider: provider,
                external_id: external_id,
                email: "ada@example.com",
                metadata: %{"binding" => "lark"}
              })

            send(parent, :first_observation_written)

            receive do
              :commit_first_observation -> result
            end
          end)
        end)
      end)

    assert_receive :first_observation_written, 5_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          MappingRequests.record_observation(%{
            provider: provider,
            external_id: external_id,
            mobile: "+14155552671",
            metadata: %{"channel" => "ops"}
          })
        end)
      end)

    refute Task.yield(second, 50)
    send(first.pid, :commit_first_observation)

    assert {:ok, %MappingRequest{}} = Task.await(first, 5_000)
    assert {:ok, merged} = Task.await(second, 5_000)
    assert merged.email == "ada@example.com"
    assert merged.mobile == "+14155552671"
    assert merged.metadata == %{"binding" => "lark", "channel" => "ops"}
  end

  test "an automatic identity write removes a pending request and blocks its recreation" do
    %{principal: principal} = human_fixture()
    provider = "lark-main"
    external_id = "ou_automatic_mapping"

    assert {:ok, %MappingRequest{}} =
             MappingRequests.record_observation(%{
               provider: provider,
               external_id: external_id,
               display_name: "Ada"
             })

    assert {:ok, %{identity: identity}} =
             Principals.upsert_platform_subject_human(%{
               uid: principal.uid,
               provider: provider,
               external_id: external_id,
               display_name: principal.display_name
             })

    assert identity.principal_uid == principal.uid
    assert MappingRequests.list_requests() == []

    assert {:ok, :already_mapped} =
             MappingRequests.record_observation(%{
               provider: provider,
               external_id: external_id,
               metadata: %{"late" => true}
             })

    assert MappingRequests.list_requests() == []
  end

  test "bind_request writes the identity to the chosen principal and removes the row" do
    %{principal: principal} = human_fixture()

    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_bind_me",
               display_name: "Bindable"
             })

    assert {:ok, %{identity: identity}} = MappingRequests.bind_request(request.id, principal.uid)
    assert identity.principal_uid == principal.uid
    assert identity.metadata["origin"] == "manual"

    assert {:ok, resolved} = Principals.resolve_platform_subject("lark-main", "ou_bind_me")
    assert resolved.uid == principal.uid
    assert MappingRequests.list_requests() == []
  end

  test "bind_request refuses agents and disabled principals" do
    %{principal: agent} = agent_fixture()
    %{principal: disabled} = human_fixture()
    assert {:ok, _principal} = Principals.disable_principal(disabled.uid)

    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_refused"
             })

    assert {:error, :not_human} = MappingRequests.bind_request(request.id, agent.uid)
    assert {:error, :principal_disabled} = MappingRequests.bind_request(request.id, disabled.uid)
    assert [_still_pending] = MappingRequests.list_requests()
  end

  test "bind_subject maps a subject proactively and clears any pending row" do
    %{principal: principal} = human_fixture()

    assert {:ok, _request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_proactive"
             })

    assert {:ok, identity} =
             MappingRequests.bind_subject(principal.uid, %{
               provider: "lark-main",
               external_id: "ou_proactive"
             })

    assert identity.principal_uid == principal.uid
    assert MappingRequests.list_requests() == []

    assert {:ok, resolved} = Principals.resolve_platform_subject("lark-main", "ou_proactive")
    assert resolved.uid == principal.uid
  end

  test "delete_request drops the row without binding" do
    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_dismissed"
             })

    assert {:ok, %MappingRequest{}} = MappingRequests.delete_request(request.id)
    assert MappingRequests.list_requests() == []
    assert {:error, :not_found} = MappingRequests.delete_request(request.id)
  end
end
