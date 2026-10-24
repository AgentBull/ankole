defmodule AnkoleWeb.BrowserAuth.LoginResult do
  @moduledoc "A completed browser login or a request to replace the temporary password."
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        complete: [
          type: :map,
          tag: :status,
          tag_value: "ok",
          constraints: [
            fields: [
              status: [type: :atom, allow_nil?: false, constraints: [one_of: [:ok]]],
              returnTo: [type: :string, allow_nil?: false]
            ]
          ]
        ],
        password_change: [
          type: :map,
          tag: :status,
          tag_value: "password_change_required",
          constraints: [
            fields: [
              status: [
                type: :atom,
                allow_nil?: false,
                constraints: [one_of: [:password_change_required]]
              ]
            ]
          ]
        ]
      ]
    ]

  def wrap({:ok, %{status: status} = value}),
    do:
      {:ok,
       %Ash.Union{type: if(status == "ok", do: :complete, else: :password_change), value: value}}

  def wrap({:error, _} = error), do: error
end
