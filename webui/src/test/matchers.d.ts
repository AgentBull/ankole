/// <reference types="bun-types" />

import type { expect } from "bun:test"
import type { TestingLibraryMatchers } from "@testing-library/jest-dom/matchers"

declare module "bun:test" {
  interface Matchers<T = unknown> extends TestingLibraryMatchers<ReturnType<typeof expect.stringContaining>, T> {}
}
