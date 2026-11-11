import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  composingKey,
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
  InputGroupTextarea,
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious,
  Spinner
} from '../src'

describe('composingKey', () => {
  test('treats active composition and keyCode 229 as IME events', () => {
    expect(composingKey({ isComposing: true, keyCode: 13 })).toBe(true)
    expect(composingKey({ isComposing: false, keyCode: 229 })).toBe(true)
    expect(composingKey({ isComposing: false, keyCode: 13 })).toBe(false)
  })
})

describe('Spinner', () => {
  test('defaults to decorative aria-hidden without hardcoded English live-region announcements', () => {
    const decorative = renderToStaticMarkup(<Spinner />)
    expect(decorative).toContain('data-slot="spinner"')
    expect(decorative).toContain('aria-hidden="true"')
    expect(decorative).not.toContain('role="status"')
    expect(decorative).not.toContain('Loading')
  })

  test('exposes role="status" automatically when labelled and suppresses it when explicitly hidden', () => {
    const labelled = renderToStaticMarkup(<Spinner aria-label="正在加载" />)
    expect(labelled).toContain('role="status"')
    expect(labelled).toContain('aria-label="正在加载"')
    expect(labelled).not.toContain('aria-hidden')

    const explicitlyHidden = renderToStaticMarkup(<Spinner aria-hidden aria-label="正在加载" />)
    expect(explicitlyHidden).toContain('aria-hidden="true"')
    expect(explicitlyHidden).not.toContain('role="status"')
  })
})

describe('Pagination', () => {
  test('propagates localized text to aria-label and keeps decorative ellipsis clean', () => {
    const defaultHtml = renderToStaticMarkup(
      <Pagination>
        <PaginationContent>
          <PaginationItem>
            <PaginationPrevious href="#prev" />
          </PaginationItem>
          <PaginationItem>
            <PaginationEllipsis />
          </PaginationItem>
          <PaginationItem>
            <PaginationNext href="#next" />
          </PaginationItem>
        </PaginationContent>
      </Pagination>
    )
    expect(defaultHtml).toContain('aria-label="Go to previous page"')
    expect(defaultHtml).toContain('aria-label="Go to next page"')
    expect(defaultHtml).not.toContain('More pages')

    const localizedHtml = renderToStaticMarkup(
      <Pagination aria-label="分页导航">
        <PaginationContent>
          <PaginationItem>
            <PaginationPrevious href="#prev" text="上一页" />
          </PaginationItem>
          <PaginationItem>
            <PaginationEllipsis aria-hidden={false} label="更多页码" />
          </PaginationItem>
          <PaginationItem>
            <PaginationNext href="#next" text="下一页" />
          </PaginationItem>
        </PaginationContent>
      </Pagination>
    )
    expect(localizedHtml).toContain('aria-label="分页导航"')
    expect(localizedHtml).toContain('aria-label="上一页"')
    expect(localizedHtml).toContain('aria-label="下一页"')
    expect(localizedHtml).toContain('>更多页码</span>')
  })
})

describe('InputOTP and InputGroup', () => {
  test('defaults InputOTP to numeric keypad and one-time-code autofill while allowing overrides', () => {
    const defaultOtp = renderToStaticMarkup(
      <InputOTP maxLength={6} value="">
        <InputOTPGroup>
          <InputOTPSlot index={0} />
        </InputOTPGroup>
      </InputOTP>
    )
    expect(defaultOtp).toContain('inputMode="numeric"')
    expect(defaultOtp).toContain('autoComplete="one-time-code"')

    const alphaOtp = renderToStaticMarkup(
      <InputOTP maxLength={6} inputMode="text" value="">
        <InputOTPGroup>
          <InputOTPSlot index={0} />
        </InputOTPGroup>
      </InputOTP>
    )
    expect(alphaOtp).toContain('inputMode="text"')
  })

  test('suppresses duplicate inner user-invalid borders inside InputGroup', () => {
    const html = renderToStaticMarkup(
      <InputGroup>
        <InputGroupAddon>https://</InputGroupAddon>
        <InputGroupInput required />
        <InputGroupTextarea disabled />
      </InputGroup>
    )
    expect(html).toContain('user-invalid:border-b-0')
    expect(html).toContain('user-invalid:shadow-none')
    expect(html).toContain('has-[:is(input,textarea):disabled]:border-b-transparent')
  })
})

describe('prefers-reduced-motion stylesheets', () => {
  test('gates emoji skin-tone and Pod completion spatial transitions behind no-preference while keeping opacity/color feedback', () => {
    const emojiCss = readFileSync(resolve(import.meta.dir, '../src/components/emoji-picker.css'), 'utf8')
    const chatCss = readFileSync(resolve(import.meta.dir, '../../../app/webapps/pod/chat.css'), 'utf8')

    expect(emojiCss).toMatch(
      /\.ankole-emoji-picker-skin-tone > div \{[\s\S]*?@media \(prefers-reduced-motion: no-preference\) \{\s*transition:\s*width/
    )
    expect(emojiCss).toMatch(
      /\.ankole-emoji-picker-tone-btn \{[\s\S]*?transition:\s*opacity[\s\S]*?background-color[\s\S]*?@media \(prefers-reduced-motion: no-preference\) \{\s*transition:\s*transform/
    )
    expect(chatCss).toMatch(
      /\.pod-chat-completion-highlight,\s*\.pod-chat-composer-menu \[data-slot='select-highlight'\] \{\s*transition: opacity 160ms ease-out;\s*@media \(prefers-reduced-motion: no-preference\) \{\s*transition:\s*translate/
    )
  })
})
