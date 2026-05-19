import "@/test/happydom"
import "@/test/testing-library"
import { describe, expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { LoginCodeHelp } from "@/apps/sessions/New"
import { BullXI18nextProvider } from "@/i18n/provider"

describe("login code help", () => {
  test("renders the webauth command hint as inline code", () => {
    document.documentElement.lang = "en-US"

    render(
      <BullXI18nextProvider>
        <LoginCodeHelp />
      </BullXI18nextProvider>,
    )

    const command = screen.getByText("/webauth")

    expect(command.tagName).toBe("CODE")
    expect(screen.getByText(/private chat/)).toBeInTheDocument()
  })
})
