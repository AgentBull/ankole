defmodule Ankole.AuthZ.Validations.GrantShape do
  @moduledoc false
  use Ash.Resource.Validation

  @node_actions ~w(node_view node_contribute node_edit node_manage node_comment)

  @impl true
  def validate(changeset, _opts, _context) do
    attrs =
      Map.new(
        ~w(principal_uid group_id source_node_id source_action target_node_id target_scope resource_pattern action)a,
        &{&1, Ash.Changeset.get_attribute(changeset, &1)}
      )

    cond do
      Enum.count([attrs.principal_uid, attrs.group_id, attrs.source_node_id], &(not is_nil(&1))) !=
          1 ->
        {:error,
         field: :principal_uid,
         message: "exactly one Principal, group, or source node is required"}

      not valid_source?(attrs) ->
        {:error,
         field: :source_action,
         message: "requires a source node, a node action, and a target node"}

      not valid_target?(attrs) ->
        {:error, field: :resource_pattern, message: "must match the typed node target and scope"}

      true ->
        :ok
    end
  end

  defp valid_source?(%{source_node_id: nil, source_action: nil}), do: true

  defp valid_source?(%{source_node_id: source, source_action: action, target_node_id: target}),
    do: not is_nil(source) and action in @node_actions and not is_nil(target) and source != target

  defp valid_target?(%{action: action} = attrs) when action in @node_actions do
    case {attrs.target_node_id, attrs.target_scope, attrs.resource_pattern} do
      {nil, nil, "drive:space:**"} ->
        true

      {nil, nil, pattern} when is_binary(pattern) ->
        Regex.match?(~r/\Adrive:private:[^*?\[\]{}]+:\*\*\z/, pattern)

      {id, scope, pattern} when is_binary(id) and scope in ["container", "self"] ->
        suffix = if scope == "container", do: "**", else: "node"
        pattern == "drive:**:#{id}:#{suffix}"

      _ ->
        false
    end
  end

  defp valid_target?(%{target_node_id: nil, target_scope: nil, resource_pattern: pattern})
       when is_binary(pattern), do: pattern != "**" and not String.starts_with?(pattern, "drive:")

  defp valid_target?(_attrs), do: false
end
