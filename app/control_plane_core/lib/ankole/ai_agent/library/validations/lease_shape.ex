defmodule Ankole.AIAgent.Library.Validations.LeaseShape do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :author_kind) do
      :human ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :review_after)),
          do: :ok,
          else: {:error, field: :review_after, message: "human lessons carry no lease"}

      :dreaming ->
        missing =
          Enum.filter(
            [:review_after, :checked_release, :checked_skill_hash],
            &is_nil(Ash.Changeset.get_attribute(changeset, &1))
          )

        errors =
          Enum.map(missing, &Ash.Error.Changes.Required.exception(field: &1, type: :attribute))

        errors =
          if Ash.Changeset.get_attribute(changeset, :evidence_job_ids) == [],
            do: [
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :evidence_job_ids,
                message: "must contain evidence"
              )
              | errors
            ],
            else: errors

        if errors == [], do: :ok, else: {:error, errors}

      _invalid ->
        :ok
    end
  end
end
