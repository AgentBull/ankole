defmodule Ankole.Pod.Validations.ChildrenView do
  @moduledoc false
  use Ash.Resource.Validation

  @allowed_keys ~w(collapsed view field_order visible_fields)
  @allowed_views ~w(list grid)
  @configurable_fields ~w(created_by updated_at created_at)
  @sorted_fields Enum.sort(@configurable_fields)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :children_view) do
      value when is_map(value) ->
        validate_map(value)

      _other ->
        {:error, field: :children_view, message: "must be an object"}
    end
  end

  defp validate_map(value) do
    cond do
      not Enum.all?(Map.keys(value), &(&1 in @allowed_keys)) ->
        {:error, field: :children_view, message: "contains unknown keys"}

      Map.has_key?(value, "collapsed") and not is_boolean(value["collapsed"]) ->
        {:error, field: :children_view, message: "collapsed must be a boolean"}

      Map.has_key?(value, "view") and value["view"] not in @allowed_views ->
        {:error, field: :children_view, message: "view must be list or grid"}

      Map.has_key?(value, "field_order") and not valid_field_order?(value["field_order"]) ->
        {:error,
         field: :children_view,
         message: "field_order must list created_by, updated_at, and created_at once each"}

      Map.has_key?(value, "visible_fields") and
          not valid_visible_fields?(value["visible_fields"]) ->
        {:error,
         field: :children_view,
         message: "visible_fields must be a duplicate-free subset of configurable fields"}

      true ->
        :ok
    end
  end

  defp valid_field_order?(fields) when is_list(fields) do
    length(fields) == 3 and Enum.all?(fields, &is_binary/1) and
      Enum.sort(fields) == @sorted_fields
  end

  defp valid_field_order?(_fields), do: false

  defp valid_visible_fields?(fields) when is_list(fields) do
    Enum.all?(fields, &(&1 in @configurable_fields)) and Enum.uniq(fields) == fields
  end

  defp valid_visible_fields?(_fields), do: false
end
