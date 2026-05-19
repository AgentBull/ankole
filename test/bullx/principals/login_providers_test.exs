defmodule BullX.Principals.LoginProvidersTestProvider do
  @behaviour BullX.Principals.LoginProvider

  @impl true
  def fetch_source("main"), do: {:ok, %{id: "main"}}
  def fetch_source(_provider_id), do: {:error, :not_found}

  def provider_ids, do: ["main"]

  @impl true
  def authorization_url(source, request) do
    {:ok, %{url: "https://idp.example.com/#{source.id}", state: request}}
  end

  @impl true
  def callback(source, _params, _state) do
    {:ok, %{"provider" => source.id, "external_id" => "external"}}
  end
end

defmodule BullX.Principals.LoginProvidersTestPlugin do
  use BullX.Plugins.Plugin, app: :login_provider_test_plugin

  @impl true
  def extensions do
    [
      %{
        point: :"bullx.principals.login_provider",
        id: "test",
        module: BullX.Principals.LoginProvidersTestProvider
      }
    ]
  end
end

defmodule BullX.Principals.LoginProvidersTest do
  use ExUnit.Case, async: true

  alias BullX.Plugins.{Discovery, Registry}
  alias BullX.Principals.LoginProviders

  test "dispatches source-scoped provider ids through enabled plugin extensions" do
    {:ok, plugin} =
      Discovery.discover_app(:login_provider_test_plugin,
        modules: [BullX.Principals.LoginProvidersTestPlugin]
      )

    name = :"login_provider_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["login_provider_test_plugin"], name: name}
    )

    assert LoginProviders.provider_ids(name) == ["main"]

    assert [%{id: "main", label: "main", provider: "test", source_id: "main"}] =
             LoginProviders.provider_options(name)

    assert {:ok, %{url: "https://idp.example.com/main", state: %{"return_to" => "/"}}} =
             LoginProviders.authorization_url("main", %{"return_to" => "/"}, name)

    assert {:ok, %{"provider" => "main", "external_id" => "external"}} =
             LoginProviders.callback("main", %{}, %{}, name)
  end
end
