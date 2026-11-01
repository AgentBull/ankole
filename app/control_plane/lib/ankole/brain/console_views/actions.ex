defmodule Ankole.Brain.ConsoleViews.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.{Claims, GetPage, Health, Objects, Recall}
  alias Ankole.Brain.Schemas.Claim

  @impl true
  def run(input, _opts, _context) do
    input.action.name
    |> action(input.arguments)
    |> Ankole.Errors.wrap(&describe/1)
    |> plain_result()
  end

  defp action(:health, _args), do: {:ok, %{health: Health.snapshot()}}
  defp action(:object_types, _args), do: {:ok, %{types: Objects.installed_type_names()}}

  defp action(:dream, _args) do
    with {:ok, result} <- Ankole.Brain.Jobs.Dreaming.enqueue(),
         do: {:ok, %{result: result}}
  end

  defp action(:show_object, args) do
    case GetPage.get_page_admin(args.slug) do
      {:ok, page} -> {:ok, %{object: page}}
      {:ambiguous, candidates} -> {:ok, %{candidates: candidates}}
      {:error, _reason} = error -> error
    end
  end

  defp action(:search_preview, args) do
    disclosure = %{
      mode: if(args[:disclosure_mode] == "strict", do: :strict, else: :relaxed),
      asker_uid: args[:asker_uid],
      present_uids: args.present_uids
    }

    with {:ok, result} <-
           Recall.recall(args.principal_uid, %{query: args.query}, disclosure: disclosure),
         do: {:ok, %{result: result}}
  end

  defp action(:principal_knowledge, args) do
    claims =
      args.principal_uid
      |> Claims.list_for_principal_audit(limit: 100)
      |> Enum.map(&claim_detail/1)

    {:ok, %{claims: claims}}
  end

  defp claim_detail(%Claim{} = claim) do
    claim
    |> Map.take([
      :id,
      :claim_type,
      :claim,
      :kind,
      :holder,
      :audience_scope,
      :object_slug,
      :conversation_id,
      :notability,
      :confidence,
      :valid_from,
      :valid_until,
      :expired_at,
      :weight,
      :active,
      :since_date,
      :until_date,
      :graded_quality,
      :graded_by,
      :resolved_by,
      :graded_confidence,
      :resolved_quality,
      :resolved_outcome,
      :resolved_at,
      :superseded_by,
      :provenance,
      :created_at
    ])
    |> Map.put(:author, claim.author && Map.from_struct(claim.author))
  end

  defp describe(:not_found),
    do: Ankole.Errors.Invalid.NotFound.exception(resource: Ankole.Brain.Schemas.Object)

  defp describe(:brain_disabled), do: {"Brain is disabled", []}
  defp describe(_reason), do: {"Brain request is invalid", []}

  defp plain_result({:ok, value}), do: {:ok, Ankole.JSON.plain(value)}
  defp plain_result(error), do: error
end
