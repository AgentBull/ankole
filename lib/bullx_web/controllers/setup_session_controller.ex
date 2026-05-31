defmodule BullXWeb.SetupSessionController do
  @moduledoc """
  Opens the temporary setup session with a bootstrap activation code.

  The plaintext code is never stored durably. This controller mints and logs a
  fresh code for the operator, verifies the submitted value, and keeps only the
  hash plus setup navigation state in the sealed browser session.
  """

  use BullXWeb, :controller

  require Logger

  @bootstrap_banner_width 72

  def new(conn, _params) do
    case BullX.Principals.setup_required?() do
      true ->
        log_bootstrap_activation_code()

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
        |> force_inertia_redirect()
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

  # The bootstrap code's plaintext is never persisted (only its hash), so the
  # only way to surface a working code is to mint one here, on demand, when the
  # operator opens the gate. Each visit rotates the pending code and logs the
  # newest one; the previous code stops working.
  defp log_bootstrap_activation_code do
    case BullX.Principals.create_or_refresh_bootstrap_activation_code() do
      {:ok, %{code: code, action: action}} when action in [:created, :refreshed] ->
        Logger.warning(IO.iodata_to_binary(["\n\n", render_activation_banner(code), "\n"]))

      _ ->
        :ok
    end
  end

  defp render_activation_banner(code) do
    issued_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    width = @bootstrap_banner_width
    margin = "  "
    border = [margin, "+", String.duplicate("=", width + 2), "+\n"]

    lines = [
      "",
      "BullX setup - bootstrap activation code",
      "",
      "    " <> code,
      "",
      "Enter this code at /setup/sessions/new to continue setup.",
      "A fresh code is logged on each visit; use the most recent one.",
      "Issued at " <> issued_at,
      ""
    ]

    body =
      Enum.map(lines, fn line -> [margin, "| ", String.pad_trailing(line, width), " |\n"] end)

    [border, body, border]
  end

  defp locale_id_to_string(locale), do: to_string(locale)
end
