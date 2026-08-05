defmodule Ankole.Plugins.ConfigSecretsTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.ConfigSecrets

  @fields [
    %{path: "clientId", encrypted: false},
    %{path: "clientSecret", encrypted: true},
    %{"path" => "nested.token", "encrypted" => true}
  ]

  test "redact removes only stored encrypted fields and reports their paths" do
    config = %{
      "clientId" => "public-id",
      "clientSecret" => "secret",
      "nested" => %{"token" => "nested-secret", "region" => "cn"}
    }

    assert ConfigSecrets.redact(@fields, config) ==
             {%{"clientId" => "public-id", "nested" => %{"region" => "cn"}},
              ["clientSecret", "nested.token"]}
  end

  test "preserve restores omitted and blank secrets but accepts replacements" do
    current = %{"clientSecret" => "old-secret", "nested" => %{"token" => "old-token"}}
    patch = %{"clientSecret" => "new-secret", "nested" => %{"token" => ""}}

    assert ConfigSecrets.preserve(@fields, patch, current) == %{
             "clientSecret" => "new-secret",
             "nested" => %{"token" => "old-token"}
           }

    assert ConfigSecrets.preserve(@fields, %{}, current) == current
  end

  test "preserve supports an explicit legacy placeholder without changing the default" do
    current = %{"clientSecret" => "old-secret"}
    patch = %{"clientSecret" => "********"}

    assert ConfigSecrets.preserve(@fields, patch, current) == patch

    assert ConfigSecrets.preserve(@fields, patch, current, ["********"]) == current
  end
end
