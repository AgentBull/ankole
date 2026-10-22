defmodule Ankole.AIGateway.Schemas.CompactionArtifact do
  @moduledoc """
  Stored compaction artifact for AIGateway history compaction.

  This table is the only durable source of compaction output. Message rows may
  point at an artifact through a checkpoint, but the summary and retained tail
  live here.
  """

  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway

  postgres do
    table("ai_gateway_compaction_artifacts")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      subject_uid: "ai_gateway_compaction_artifacts_subject_uid_fkey",
      conversation_id: "ai_gateway_compaction_artifacts_conversation_id_fkey"
    )

    check_constraints do
      check_constraint(:content, "ai_gateway_compaction_artifacts_content_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7)

    attribute(:content, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      constraints: [allow_datetime?: true]
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :store do
      accept([:id, :subject_uid, :conversation_id, :content])

      validate(
        fn changeset, _context ->
          validate_content(Ash.Changeset.get_attribute(changeset, :content))
        end,
        only_when_valid?: true
      )
    end
  end

  @type t :: %__MODULE__{}

  @doc """
  Tells whether `binding` can tie a version 3 upstream artifact to its
  provider row: non-empty `provider_row_id`, `provider_updated_at`, and
  `model` strings.
  """
  @spec valid_upstream_binding?(term()) :: boolean()
  def valid_upstream_binding?(%{
        "provider_row_id" => provider_row_id,
        "provider_updated_at" => provider_updated_at,
        "model" => model
      }) do
    Enum.all?([provider_row_id, provider_updated_at, model], fn value ->
      is_binary(value) and String.trim(value) != ""
    end)
  end

  def valid_upstream_binding?(_binding), do: false

  defp validate_content(%{"version" => 2} = content) do
    cond do
      not is_map(Map.get(content, "summary")) ->
        invalid("version 2 must include a summary object")

      not is_list(Map.get(content, "output")) ->
        invalid("version 2 must include output items")

      true ->
        validate_brain_context_pack(content)
    end
  end

  defp validate_content(%{"version" => 3} = content) do
    cond do
      Map.get(content, "source") != "upstream" ->
        invalid("version 3 source must be upstream")

      not valid_upstream_binding?(Map.get(content, "binding")) ->
        invalid("version 3 must include a binding object")

      not is_list(Map.get(content, "output")) or Map.get(content, "output") == [] ->
        invalid("version 3 must include output items")

      true ->
        validate_brain_context_pack(content)
    end
  end

  defp validate_content(_content), do: invalid("must use version 2 or 3")

  defp validate_brain_context_pack(content) do
    case Map.fetch(content, "brain_context_pack") do
      :error ->
        :ok

      {:ok, pack} when is_list(pack) ->
        if Enum.all?(pack, &brain_context_pack_message?/1),
          do: :ok,
          else: invalid("brain_context_pack must contain message items")

      {:ok, _invalid} ->
        invalid("brain_context_pack must contain message items")
    end
  end

  defp invalid(message), do: {:error, field: :content, message: message}

  defp brain_context_pack_message?(%{"type" => "message", "role" => "user", "content" => parts})
       when is_list(parts) do
    Enum.all?(parts, fn
      %{"type" => "input_text", "text" => text} when is_binary(text) -> true
      _part -> false
    end)
  end

  defp brain_context_pack_message?(_item), do: false
end
