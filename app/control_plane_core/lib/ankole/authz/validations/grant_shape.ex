defmodule Ankole.AuthZ.Validations.GrantShape do
  @moduledoc false
  use Ash.Resource.Validation

  @page_actions ~w(page_view page_edit page_manage)

  @impl true
  def validate(changeset, _opts, _context) do
    attrs =
      Map.new(
        ~w(principal_uid group_id source_page_id source_action target_page_id target_scope resource_pattern action)a,
        &{&1, Ash.Changeset.get_attribute(changeset, &1)}
      )

    cond do
      Enum.count([attrs.principal_uid, attrs.group_id, attrs.source_page_id], &(not is_nil(&1))) !=
          1 ->
        {:error,
         field: :principal_uid,
         message: "exactly one Principal, group, or source Page is required"}

      not valid_source?(attrs) ->
        {:error,
         field: :source_action,
         message: "requires a source Page, a Page action, and a target Page"}

      not valid_target?(attrs) ->
        {:error, field: :resource_pattern, message: "must match the typed Page target and scope"}

      true ->
        :ok
    end
  end

  defp valid_source?(%{source_page_id: nil, source_action: nil}), do: true

  defp valid_source?(%{source_page_id: source, source_action: action, target_page_id: target}),
    do: not is_nil(source) and action in @page_actions and not is_nil(target) and source != target

  defp valid_target?(%{action: action} = attrs) when action in @page_actions do
    case {attrs.target_page_id, attrs.target_scope, attrs.resource_pattern} do
      {nil, nil, "pod:space:**"} ->
        true

      {nil, nil, pattern} when is_binary(pattern) ->
        Regex.match?(~r/\Apod:private:[a-z0-9_-]+:\*\*\z/, pattern)

      {id, scope, pattern} when is_binary(id) and scope in ["container", "self"] ->
        suffix = if scope == "container", do: "**", else: "page"
        pattern == "pod:**:#{id}:#{suffix}"

      _ ->
        false
    end
  end

  defp valid_target?(%{target_page_id: nil, target_scope: nil, resource_pattern: pattern})
       when is_binary(pattern), do: pattern != "**" and not String.starts_with?(pattern, "pod:")

  defp valid_target?(_attrs), do: false
end
