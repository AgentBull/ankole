defmodule BullXWeb.SetupSessionController do
  @moduledoc false

  use BullXWeb, :controller

  require Logger

  def new(conn, _params) do
    case BullX.Principals.setup_required?() do
      true ->
        conn
        |> BullXWeb.SetupAuth.put_no_store()
        |> assign(:page_title, "Setup")
        |> BullXWeb.SetupAuth.assign_props(%{
          app_name: "BullX",
          form_action: ~p"/setup/sessions",
          current_locale:
            BullX.I18n.default_locale().requested_locale_id |> locale_id_to_string(),
          available_locales: Enum.map(BullX.I18n.available_locales(), &locale_id_to_string/1),
          error: Phoenix.Flash.get(conn.assigns[:flash] || %{}, "error")
        })
        |> render_inertia("setup/sessions/New")

      false ->
        redirect(conn, to: ~p"/")
    end
  end

  def create(conn, params) do
    conn =
      conn
      |> BullXWeb.SetupAuth.put_no_store()
      |> BullXWeb.SetupAuth.clear_setup_session()

    payload = normalize_payload(params)
    bootstrap_code = normalize_code(payload["bootstrap_code"])

    Process.sleep(100)

    case BullX.Principals.verify_bootstrap_activation_code_for_setup(bootstrap_code) do
      {:ok, code_hash} ->
        apply_locale(payload["locale"])

        conn
        |> configure_session(renew: true)
        |> put_session(:bootstrap_activation_code_hash, code_hash)
        |> put_session(:bootstrap_activation_code_plaintext, bootstrap_code)
        |> put_session(:setup_step, "plugins")
        |> redirect(to: ~p"/setup")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Bootstrap activation code is invalid or expired.")
        |> redirect(to: ~p"/setup/sessions/new")
    end
  end

  defp normalize_payload(%{"setup" => %{} = setup}), do: setup
  defp normalize_payload(params), do: params

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp normalize_code(_code), do: ""

  defp apply_locale(locale) when is_binary(locale) do
    available = Enum.map(BullX.I18n.available_locales(), &locale_id_to_string/1)

    case locale in available do
      true ->
        :ok = BullX.Config.put("bullx.i18n_default_locale", locale)
        _ = BullX.I18n.reload()
        :ok

      false ->
        Logger.warning("invalid setup locale #{inspect(locale)}; available=#{inspect(available)}")
        :ok
    end
  end

  defp apply_locale(_locale), do: :ok

  defp locale_id_to_string(locale), do: to_string(locale)
end
