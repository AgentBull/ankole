defmodule Ankole.Pod.Applets.Approvals do
  @moduledoc "Records and reads Human decisions on Applet requests."

  require Ash.Query
  require Ash.Sort

  alias Ankole.{AuthZ, Principals, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.{Access, AppletApproval, Pages}
  alias Ankole.Pod.Pages.Tree

  def request(page_id, %Actor{} = actor, %Actor{} = requester, input) when is_map(input) do
    with {:ok, key} <- text(input["requestKey"], 160),
         {:ok, summary} <- text(input["summary"], 500),
         {:ok, details} <- optional_text(input["details"], 4000),
         {:ok, reviewer_uid} <- Principals.normalize_uid(input["reviewerUid"]),
         true <- String.valid?(reviewer_uid) and not String.contains?(reviewer_uid, "\0") do
      attrs = %{
        page_id: page_id,
        request_key: key,
        requester_uid: Actor.uid(requester),
        reviewer_uid: reviewer_uid,
        summary: summary,
        details: details
      }

      request_with_authority(page_id, actor, requester, attrs)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def request(_page_id, _actor, _requester, _input), do: {:error, :invalid_request}

  defp request_with_authority(page_id, actor, requester, attrs) do
    with :ok <- AuthZ.validate_turn_authority(actor.turn_authority) do
      Repo.transact_top_level(fn ->
        Tree.lock_tree(shared: true)
        # Take the reviewer's Principal lock before the Job fence and Page row.
        reviewer = Principals.lock_principal_in_tx(attrs.reviewer_uid, :share)

        with :ok <- AuthZ.authorize_turn_in_tx(actor.turn_authority),
             {:ok, page} <- authorize_page(actor, page_id, "node_contribute"),
             {:ok, _} <- Access.authorize(requester, page, "node_view", trash: false),
             do: find_or_request(page, attrs, reviewer)
      end)
    end
  end

  def get(page_id, %Actor{} = actor, id) do
    with {:ok, id} <- approval_id(id) do
      Repo.transact_top_level(fn ->
        with {:ok, _page} <- authorize_page(actor, page_id, "node_view"),
             {:ok, approval} <- fetch(page_id, id),
             true <- Actor.uid(actor) in [approval.requester_uid, approval.reviewer_uid] do
          {:ok, result(approval)}
        else
          false -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  def get(_page_id, _actor, _id), do: {:error, :forbidden}

  def list(page_id, %Actor{} = actor) do
    uid = Actor.uid(actor)

    Repo.transact_top_level(fn ->
      with {:ok, _page} <- authorize_page(actor, page_id, "node_view") do
        approvals =
          AppletApproval
          |> Ash.Query.filter(
            page_id == ^page_id and (requester_uid == ^uid or reviewer_uid == ^uid)
          )
          |> Ash.Query.sort([
            {Ash.Sort.expr_sort(status == :pending, :boolean), :desc},
            inserted_at: :desc,
            id: :desc
          ])
          |> Ash.Query.limit(100)
          |> Ankole.Ash.read!()

        {:ok, %{approvals: Enum.map(approvals, &result/1)}}
      end
    end)
  end

  def list(_page_id, _actor), do: {:error, :forbidden}

  def decide(page_id, %Actor{principal: %{type: :human}, turn_authority: nil} = actor, input)
      when is_map(input) do
    with {:ok, id} <- approval_id(input["id"]),
         {:ok, decision} <- decision(input["decision"]),
         {:ok, note} <- optional_text(input["note"], 1000) do
      Access.write(
        nil,
        fn ->
          with {:ok, _} <- Principals.lock_active_human_in_tx(Actor.uid(actor)),
               {:ok, _page} <- authorize_page(actor, page_id, "node_view"),
               {:ok, approval} <- fetch(page_id, id, lock: true),
               true <- Actor.uid(actor) == approval.reviewer_uid do
            decide_in_tx(approval, decision, note)
          else
            false -> {:error, :forbidden}
            error -> error
          end
        end,
        shared_tree: true
      )
    end
  end

  def decide(_page_id, _actor, _input), do: {:error, :forbidden}

  defp authorize_page(actor, page_id, action) do
    with {:ok, %{type: :applet} = page} <- Pages.lock(page_id, :share),
         do: Access.authorize(actor, page, action, trash: false),
         else: (
           {:ok, _} -> {:error, :not_found}
           error -> error
         )
  end

  defp find_or_request(page, attrs, reviewer) do
    case AppletApproval
         |> Ash.Query.filter(page_id == ^page.id and request_key == ^attrs.request_key)
         |> Ankole.Ash.read_one!() do
      nil -> create_request(page, attrs, reviewer)
      approval -> existing_request(approval, attrs)
    end
  end

  defp create_request(page, attrs, {:ok, %{type: :human, status: :active} = reviewer}) do
    with {:ok, _} <- Access.authorize(Actor.new(reviewer), page, "node_view", trash: false),
         {:ok, approval, _} <- Ankole.Ash.insert_if_absent(AppletApproval, :request_in_tx, attrs) do
      existing_request(approval, attrs)
    end
  end

  defp create_request(_page, _attrs, _reviewer), do: {:error, :invalid_request}

  defp existing_request(approval, attrs) do
    if Map.take(approval, Map.keys(attrs)) == attrs,
      do: {:ok, result(approval)},
      else: {:error, :approval_conflict}
  end

  defp fetch(page_id, id, opts \\ []) do
    query = Ash.Query.filter(AppletApproval, page_id == ^page_id and id == ^id)

    approval =
      if opts[:lock],
        do:
          query
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!(lock_identity: {"pod_applet_approvals", id}),
        else: Ankole.Ash.read_one!(query)

    if approval, do: {:ok, approval}, else: {:error, :not_found}
  end

  defp decide_in_tx(%AppletApproval{status: :pending} = approval, decision, note) do
    with {:ok, saved} <-
           Ankole.Ash.update(approval, :decide_in_tx, %{
             status: decision,
             decided_at: DateTime.utc_now(),
             note: note
           }) do
      {:ok, result(saved)}
    end
  end

  defp decide_in_tx(%AppletApproval{status: decision, note: note} = approval, decision, note),
    do: {:ok, result(approval)}

  defp decide_in_tx(_approval, _decision, _note), do: {:error, :approval_conflict}

  defp result(approval) do
    %{
      id: approval.id,
      requestKey: approval.request_key,
      requesterUid: approval.requester_uid,
      reviewerUid: approval.reviewer_uid,
      summary: approval.summary,
      details: approval.details,
      status: Atom.to_string(approval.status),
      requestedAt: DateTime.to_iso8601(approval.inserted_at),
      decidedAt: approval.decided_at && DateTime.to_iso8601(approval.decided_at),
      note: approval.note
    }
  end

  defp approval_id(id) do
    case Ankole.Ecto.UUIDv7.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_request}
    end
  end

  defp decision("approved"), do: {:ok, :approved}
  defp decision("rejected"), do: {:ok, :rejected}
  defp decision(_), do: {:error, :invalid_request}

  defp optional_text(nil, _limit), do: {:ok, nil}
  defp optional_text(value, limit), do: text(value, limit)

  defp text(value, limit) when is_binary(value) and byte_size(value) <= limit * 4 do
    value = String.trim(value)

    if value != "" and not String.contains?(value, "\0") and
         length(String.codepoints(value)) <= limit,
       do: {:ok, value},
       else: {:error, :invalid_request}
  end

  defp text(_value, _limit), do: {:error, :invalid_request}
end
