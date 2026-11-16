defmodule Ankole.IdentityProviders.ErrorDescription do
  @moduledoc false

  alias Ankole.IdentityProviders

  @spec describe(term()) ::
          {String.t(), [map()]}
          | {:conflict, String.t(), [map()]}
          | Exception.t()
          | nil
  def describe(reason) when reason in [:not_found, :unknown_identity_provider_adapter],
    do: Ankole.Errors.Invalid.NotFound.exception(resource: IdentityProviders)

  def describe({reason, _})
      when reason in [:unknown_identity_provider, :unknown_identity_provider_adapter],
      do: Ankole.Errors.Invalid.NotFound.exception(resource: IdentityProviders)

  def describe(:platform_app_bound_to_another_tenant),
    do: {:conflict, "This platform application belongs to another tenant.", []}

  def describe(:identity_provider_exists),
    do: {:conflict, "An identity provider with this ID already exists. Choose another ID.", []}

  def describe({:platform_application_identity_unavailable, reference}),
    do:
      {"Could not verify an existing platform application. Repair its credentials and try again.",
       [reference]}

  def describe(:platform_application_identity_unavailable),
    do: {"Could not verify the platform application. Check its credentials and availability.", []}

  def describe(:sync_disabled), do: {"Directory sync is disabled for this provider.", []}
  def describe(:sync_unsupported), do: {"This provider does not support directory sync.", []}

  def describe(:directory_review_changed),
    do:
      {:conflict,
       "The directory evidence changed. Read the current snapshot and review it again.", []}

  def describe({:missing, path}),
    do: {"#{path} is required.", [%{path: to_string(path), kind: "missing"}]}

  def describe({reason, path})
      when reason in [:invalid_string, :invalid_field, :invalid_boolean] and is_binary(path),
      do: {"#{path} is invalid.", [%{path: path, kind: "invalid"}]}

  def describe({:invalid_integer_range, path, min, max}),
    do:
      {"#{path} must be an integer between #{min} and #{max}.", [%{path: path, kind: "invalid"}]}

  def describe({:invalid_enum, path, values}),
    do: {"#{path} must be one of: #{Enum.join(values, ", ")}.", [%{path: path, kind: "invalid"}]}

  def describe({:invalid_id, field, _}),
    do:
      {"The identifier is invalid.",
       [%{path: to_string(field), message: "is not a valid identifier"}]}

  def describe(_), do: nil
end
