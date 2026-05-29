defmodule BullX.Principals.HumanUser do
  @moduledoc """
  Human-specific extension row for a Human Principal.

  Email and phone are optional authentication and matching facts. They are
  normalized before storage and remain unique when present.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @type t :: %__MODULE__{}

  schema "human_users" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :email, :string
    field :phone, :string

    timestamps()
  end

  def changeset(human_user, attrs) do
    human_user
    |> cast(attrs, [:principal_uid, :email, :phone])
    |> normalize_blank([:email, :phone])
    |> normalize_email()
    |> validate_required([:principal_uid])
    |> validate_format(:email, @email_format, message: "is not a valid email")
    |> normalize_phone()
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:principal_uid, name: :human_users_pkey)
    |> unique_constraint(:email)
    |> unique_constraint(:phone)
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, &String.downcase/1)
  end

  defp normalize_phone(changeset) do
    case fetch_change(changeset, :phone) do
      {:ok, nil} ->
        changeset

      {:ok, phone} ->
        case BullX.Ext.phone_normalize_e164(phone) do
          e164 when is_binary(e164) -> put_change(changeset, :phone, e164)
          {:error, _reason} -> add_error(changeset, :phone, "is not a valid phone number")
        end

      :error ->
        changeset
    end
  end
end
