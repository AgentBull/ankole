defmodule Ankole.Principals.HumanUser do
  @moduledoc """
  Human-specific profile row keyed by `principals.uid`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @email_format ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  schema "human_users" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :email, :string
    field :mobile, :string
    field :job_title, :string

    timestamps()
  end

  @doc false
  def changeset(human_user, attrs) do
    human_user
    |> cast(attrs, [:principal_uid, :email, :mobile, :job_title])
    |> normalize_blank([:email, :mobile, :job_title])
    |> normalize_email()
    |> normalize_mobile()
    |> validate_required([:principal_uid])
    |> validate_format(:email, @email_format, message: "is invalid")
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:principal_uid, name: :human_users_pkey)
    |> unique_constraint(:email, name: :human_users_email_index)
    |> unique_constraint(:mobile, name: :human_users_mobile_index)
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  defp normalize_mobile(changeset) do
    case fetch_change(changeset, :mobile) do
      {:ok, nil} ->
        changeset

      {:ok, value} ->
        case NativeKernel.phone_normalize_e164(value) do
          normalized when is_binary(normalized) -> put_change(changeset, :mobile, normalized)
          {:error, _reason} -> add_error(changeset, :mobile, "must be E.164")
        end

      :error ->
        changeset
    end
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end
end
