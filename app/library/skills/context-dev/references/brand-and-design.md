# Brand and Design

Company profiles, design systems, screenshots, and industry codes. Each example is one common shape, not a procedure.

## brand-retrieve-unified

All arguments go inside one `body` object, and `body.type` selects the lookup. The six shapes are exclusive: send the fields of one shape only.

| `body.type` | Required field | Use it for |
| --- | --- | --- |
| `by_domain` | `domain` | The company website is known |
| `by_name` | `name` (3–30 characters) | Only the company name is known. `country_gl` is a two-letter hint |
| `by_email` | `email` | Lead or onboarding enrichment. The domain comes from the address |
| `by_ticker` | `ticker` (1–15 characters) | A listed company. `ticker_exchange` defaults to NASDAQ |
| `by_transaction` | `transaction_info` | A card or bank descriptor such as `AMZN MKTP US` |
| `by_direct_url` | `direct_url` | One specific page, with no database lookup or enrichment |

The tool description also names ISIN, but the `body` union has no ISIN shape. Read the current schema before you build an ISIN lookup on it.

Most shapes also accept `force_language`, `maxSpeed`, `maxAgeMs`, `timeoutMS`, and `tags`. `by_transaction` refuses `maxAgeMs`. `by_direct_url` refuses `maxSpeed`, `force_language`, and `maxAgeMs`, because it only reads the one page.

```json
{ "body": { "type": "by_domain", "domain": "stripe.com" } }
```

`by_transaction` becomes far more exact with disambiguators: `mcc`, `city`, `country_gl`, and `phone`. Set `high_confidence_only: true` when a wrong merchant is worse than no merchant.

```json
{
  "body": {
    "type": "by_transaction",
    "transaction_info": "SQ *COFFEE BAR",
    "city": "Austin",
    "country_gl": "us",
    "high_confidence_only": true
  }
}
```

### The returned brand object

The response envelope is `{ status, code, brand }`. Any field can be absent, so give every read a fallback.

| Field | Notes |
| --- | --- |
| `domain`, `title`, `description`, `slogan` | Identity and copy |
| `colors[]` | `{ hex, name }` ordered by prominence. `name` is generated, so key on `hex` |
| `logos[]` | `{ url, mode, type, resolution, colors[] }`. `mode` is `light`, `dark`, or `has_opaque_background`; `type` is `icon` (square) or `logo` (horizontal) |
| `backdrops[]` | Hero imagery with colors and resolution |
| `socials[]` | `{ type, url }` across about 30 network types |
| `address` | `street`, `city`, `state_province`, `state_code`, `country`, `country_code`, `postal_code` |
| `stock` | `{ ticker, exchange }`, or null for a private company |
| `industries.eic[]` | `{ industry, subindustry }` in Context's own taxonomy. NAICS and SIC come from their own tools |
| `links` | `careers`, `blog`, `pricing`, `contact`, `terms`, `privacy`, each nullable |
| `email`, `phone` | Public contact details when found |
| `primary_language`, `is_nsfw` | Detected site language and a safe-content flag |

Filter `logos[]` by `mode` and `type` for the placement you need. `logos[0]` is not a choice.

`by_direct_url` returns only what one page can show: `domain`, `title`, `description`, `logos` (URLs alone), `socials`, `email`, `phone`, and `links`. It omits `colors`, `backdrops`, `industries`, `stock`, and `address`.

An email at a free or disposable provider returns `422`. Treat it as "skip enrichment", not as a failure. A domain with no match returns `400 NOT_FOUND` and costs nothing.

## get-brand

Takes `domain` and optional `maxSpeed`, and renders the profile as a visual card. Use it when a person will look at the result. Use `brand-retrieve-unified` when the fields feed later work.

## web-styleguide and web-fonts

Both take exactly one of `domain` or `directUrl`. Sending both, or neither, fails. Both also accept `maxAgeMs`, which defaults to about 90 days and is clamped between 1 day and 1 year.

`web-styleguide` costs 10 credits and returns `styleguide` with:

- `mode`: `light` or `dark`. `colorScheme` emulates the browser preference and is part of the cache key.
- `colors`: `accent`, `background`, `text`.
- `typography`: `headings.h1` to `headings.h4` and `p`, each with family, fallbacks, size, weight, line height, and letter spacing.
- `elementSpacing` and `shadows`: `xs` to `xl`, and `sm` to `xl` plus `inner`.
- `components`: `button.primary`, `button.secondary`, `button.link`, and `card`. Each carries a ready `css` string. The card uses `textColor` where the buttons use `color`.
- `fontLinks`: family to downloadable files. It can be `{}` when nothing resolves.

`web-fonts` costs 5 credits and returns `fonts[]`, each with `font`, `uses[]`, `fallbacks[]`, `num_elements`, `num_words`, `percent_elements`, and `percent_words`. Word share measures text volume and element share measures DOM coverage, so a monospace font can lead on elements and carry almost no words. `fontLinks` is omitted when nothing resolves.

## web-screenshot

Takes exactly one of `domain` or `directUrl`, and costs 5 credits. `fullScreenshot` is the string `"true"` or `"false"`, not a boolean. `viewport` accepts `width` 240–7680 and `height` 240–4320. `page` finds a page type such as `pricing`, `careers`, or `login`, and works only with `domain`. `colorScheme` selects the light or dark appearance, `handleCookiePopup` dismisses a consent banner first, and `waitForMs` defaults to 3000.

`scrollOffset` returns one viewport-sized slice that starts at that Y offset, so a long page can be read in steps of the viewport height.

The response carries `screenshot` as a hosted image URL, plus `screenshotType`, `width`, and `height`. There are no inline bytes; download the URL when you need the file.

## web-naics and web-sic

Both take `input`, where a domain classifies better than a name, and both cost 10 credits. `minResults` and `maxResults` are 1–10, and default to 1 and 5.

`web-naics` returns `codes[]` of `{ code, name, confidence }` against 2022 NAICS. `web-sic` takes `type` of `original_sic` (1987 SIC, the default) or `latest_sec` (the current SEC list). `original_sic` codes carry `majorGroup` and `majorGroupName`; `latest_sec` codes carry `office`.

```json
{ "input": "stripe.com", "maxResults": 3 }
```

Report the confidence with the code. A `low` confidence code is a candidate, not an answer.
