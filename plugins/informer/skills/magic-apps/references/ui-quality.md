# UI Quality Bar

> **Load this reference when:** building or reshaping any app screen — page layouts, dialogs, lists and tables, forms, data loading, empty states, app icons. Every rule here is a **must**, not a taste: a screen that breaks one is not done.
>
> **Not in this file:** light/dark theme plumbing (App Context in `SKILL.md`), `docs.html` (`docs-html.md`), widget cards (`widgets.md`).

Six rules. They apply to every app and every screen, including admin screens and "just a quick" tool.

**Before designing anything, load the `frontend-design` skill** (Anthropic's `frontend-design` plugin from the official Claude Code marketplace; invoke `/frontend-design:frontend-design`, or `/plugin install frontend-design@claude-plugins-official` if it isn't present). It sets the aesthetic direction — palette, typography, layout choices grounded in the app's subject — so the app doesn't read as a templated default. This file is the engineering floor underneath that direction, not a substitute for it. If the `impeccable` plugin is installed, its audit and polish commands make a good second pass once screens exist.

## 1. Every page works on a phone — designed screen by screen

Apps run on phones and tablets as a matter of course, not as an afterthought, and each mode below constrains the page differently. A global "make it responsive" pass is not enough: **walk every screen, in every mode it will be seen in, and decide its phone layout deliberately.** Design at **360 px** first, then widen.

### The mobile modes

| Mode | What the platform does | What it means for your page |
|---|---|---|
| **Inside Informer GO** (phone/tablet app) | Your page is an iframe under GO's own title bar and chat bar; the status-bar safe area and GO's bars are outside your frame. When the on-screen keyboard opens, GO **shrinks your frame's height** to the visible area (the keyboard does not overlay you). Theme arrives as `?theme=`; `openChat()` opens GO's chat sheet; `postMessage({ type: 'informer:openApp', appId, path, query })` deep-links to another app. | Your document *is* the viewport: fill it, no outer margins, no `100vh` hacks (`height: 100%` on the root). Assume no room for your own top bar; keep headers compact. Keyboard-safe forms come free, but a fixed bottom action bar must stay above the shrunken frame's bottom edge (it does, if it is positioned against your document, not the window). |
| **Home-screen tile** (`/apps/{id}/launch`, "Add to Home Screen") | A top-level, chrome-less document: `apple-mobile-web-app-capable`, status-bar style from the theme, `theme-color`, your icon rasterized to 180 px. The platform injects `<meta name="viewport" content="width=device-width, initial-scale=1">` **only if you ship none** — no `viewport-fit=cover`. `window.__INFORMER__.standalone === true`, plus `appDeepLink` (`informer://go/apps/<naturalId>`) and `openInApp()` so *you* can offer an "Open in Informer GO" notice; the platform draws none. | Declare your own viewport meta with `viewport-fit=cover` and pad the notch/home-indicator edges with `env(safe-area-inset-*)`, or accept the default letterboxing. Use `100dvh`, not `100vh`. The browser keyboard behaves like Safari's — `scrollIntoView` the focused field. Decide whether and where to show the open-in-GO notice; it is the only "chrome" you will get. |
| **Browser tab** (`/view` inside Informer's web UI, desktop or mobile browser) | Sandboxed iframe (cookies blocked; the injected script handles auth), same viewport injection as GO, Informer's web chrome around you. | Same layout as the GO mode. On a phone browser you also lose GO's keyboard handling, so treat it like the tile mode for forms. |
| **Widget card** on a GO dashboard | Your `public/widgets/*` entry rendered in a fixed-row-height grid: 4 columns on desktop, **2 columns under 600 px**, so a 1-column widget is half a phone width. | A widget must read at roughly 160 px wide: one number, one sparkline, one list of three — not a shrunken dashboard. See `widgets.md`. |
| **Own origin** (per-app origin, optional PWA install) | Top-level document on the app's own origin; your own `manifest.webmanifest` and icon set drive install (see rule 6). | Tile-mode rules apply, plus a real manifest. |

Injected in every mode: `overscroll-behavior: none` on `html, body`, `-webkit-user-drag: none` and no touch callout on images, links and iframes. So: no pull-to-refresh, no rubber-band scroll to lean on, no long-press link menus — provide explicit refresh and share affordances where those gestures would have done the job.

### The screen-by-screen pass

For each screen, pick the phone layout from the matching row and write it down before building:

| Screen type | Phone layout |
|---|---|
| **Navigation** | Top-level sections become a bottom tab bar (five at most) or a drawer behind a menu button; the current section's title in a compact header. Provide your own back affordance inside multi-level flows — GO's bars are Informer's, not yours. |
| **List** | Rows become cards showing the two or three fields that matter; search sticks to the top; filters move into a bottom sheet with a result count; bulk actions become a selection mode with a sticky action bar. |
| **Table / grid** | Under ~600 px either collapse to the card list above or scroll horizontally with the first column pinned and a **Sort** menu replacing hidden headers (rule 4 still holds). Never shrink the type to fit. |
| **Detail** | Single column; metadata as a stacked key/value list; the primary action in a sticky bottom bar; secondary actions in an overflow menu. Related lists become collapsible sections. |
| **Form / dialog** | Full-screen sheet with Cancel and Save in its header; inputs full-width; native pickers on touch (`<input type="date">`); no nested dialogs; keep the focused field visible when the keyboard opens. |
| **Board / multi-column** | One column at a time with a segmented control or swipe, or horizontal scroll with snap points; every drag-and-drop gets a touch fallback (a "Move to…" menu). |
| **Dashboard / chart** | Single column of cards; charts resize with their container (`ResizeObserver`), legends below, values on tap rather than hover; dense number tables become value + sparkline. |
| **Settings / admin** | Grouped lists with right-aligned controls; destructive actions confirmed in a bottom sheet, never a bare browser `confirm()`. |
| **Empty state / onboarding** | One message, one action, fits without scrolling on a 360×640 viewport. |

### Mechanics that hold across modes

- Fluid layout: grid/flex with `minmax()`, `clamp()` for type, no fixed pixel widths on containers. Anything wide (tables, charts, code) scrolls inside its own `overflow-x: auto` box — the page body never scrolls sideways.
- Touch targets ≥ 44 px, primary actions reachable with a thumb.
- Dialogs go full-screen under ~600 px and stay centered on desktop.
- Verify each screen at 360×640 and 390×844 with touch emulation in dev tools, then in Informer GO on a real phone or simulator (keyboard, safe areas), then as a home-screen tile from Safari. `npm run dev` enforces none of this.

## 2. No pop-in: reserve the space before the content arrives

The symptom: a dialog that grows once its data lands, a list that jumps when a spinner is swapped for rows, a header that shifts when a count arrives, an image that pushes text down. Each one is a bug.

- **Skeletons** in the exact shape of the content: same row height, same column count, same card size. A centered spinner in an empty box is not a skeleton.
- **Reserve dimensions**: `min-height` on dialogs and cards, explicit `width`/`height` or `aspect-ratio` on images and charts, fixed-height headers with counts shown as `—` until known.
- **Dialogs keep one size across their own states** (loading → form → confirmation): size for the largest state and swap the content inside it. Never let a dialog shrink after the user has started interacting with it.
- Fade new content in inside its reserved box; do not animate height.
- Measure: Lighthouse CLS under 0.1, and watch every load and route change with your own eyes.

## 3. The screen reflects every action immediately

The failure everyone ships: create the first record and the empty state stays; add an option and a dropdown on another panel still lacks it; delete a row and the count in the header doesn't move. **The first action is the worst** because empty states are usually computed once and never revisited.

React apps use **TanStack Query for all server state**, consistently — not on some screens.

- `@tanstack/react-query` v5, pinned to an exact version, one `QueryClient` at the root.
- Every read is a `useQuery` with a structured key (`['issues', { project }]`). Empty states derive from the query's data, never from a one-time flag.
- Every write is a `useMutation` whose `onSuccess` invalidates **every** key that can show the result — the list, the count, the dropdown options, the detail — or writes the returned row into the cache. Keep the invalidation list beside the mutation, not scattered through components.
- Dependent lists (the dropdown of "things that exist") read the same query key as the list they mirror, so one invalidation refreshes both.
- Optimistic updates for toggles and reorders, rolled back on error.
- No `useEffect` + `fetch` + `useState` for server data once TanStack is in. Mixing the two is exactly how one screen goes stale.

Non-React apps follow the same rules with one mechanism per app (a single store, or the framework's query library). Test it the hard way: on a fresh workspace, perform each create/update/delete as the **first** action and confirm every surface that could show it updates without a reload.

## 4. Table headers sort

Every column header in every table is clickable to sort (ascending → descending → off), with a visible indicator and `aria-sort` on the header cell.

- Data grids use **AG Grid Community**: `ag-grid-community` + `ag-grid-react` (MIT, pin exact versions). Columns sort by default there — don't switch it off. Enterprise modules only when a license key is supplied. Drive its theme from the app's light/dark so it never looks pasted in.
- Small tables may hand-roll a `<th><button>` with sort state; still sortable, still indicated.
- Sort by value (numbers, dates), not by display string. Once a table is paginated, sort server-side via query params. Keep the current sort across refetches.

## 5. Vertical rhythm and breathing room

- One spacing scale — 4 / 8 / 12 / 16 / 24 / 32 px — and a small set of type sizes. Two neighbours on different pitches is the most common rhythm bug.
- Proximity: gaps inside a group are clearly smaller than gaps between groups (about 2:1). A label sits closer to its field than to the previous field.
- Headings attach downward: more space above a section heading than below it (about 1.5:1), so it reads as the name of what follows.
- Nothing flush: no text against a container edge, no card against the viewport edge (page gutter ≥ 16 px on mobile), no label touching an input.
- Not too much either: density increases down the hierarchy (page > card > row). Padding every level equally makes a page airy and structureless at once.
- Separate with space first; add a hairline only where space alone can't (dense tables, scrolling lists). Both at once is double-signalling.
- Measure gap ratios in dev tools before adjusting; then look.

## 6. Icons: bright, distinct, and present everywhere the app appears

Ship `public/favicon.svg` and the platform derives most surfaces from it:

| Surface | Source |
|---|---|
| App gallery tile — desktop and Informer GO mobile | `favicon.svg` (the tile is ~70 px on a phone) |
| Browser tab | `favicon.svg` (the platform injects the `<link>`) |
| iOS / Android home-screen tile from `/launch` | `/apps/{id}/launch/icon-180.png`, rasterized by the platform from `favicon.svg` onto an opaque background |
| Marketplace listing | `favicon.svg`, read by `informer-publish` / `informer-ci` |
| PWA install when the app runs on its own origin | Your own `public/manifest.webmanifest` + PNG set — the platform does not generate a manifest |

**Brightness.** The earlier duotone rule (one hue at 100% + 35% on a deep background) kept icons from being ugly, and made them dark and interchangeable instead. Now:

- Saturated, bright tile colors: a mid-tone background (Tailwind 500–600 range) or a two-stop gradient within one hue family, with a **white or near-white mark**. A light tile with a saturated mark is the other good option. Reserve dark navy/forest backgrounds for security and admin apps.
- **Distinct from siblings.** The gallery shows every installed app side by side; pick a hue no sibling app on the install uses, and vary the mark's silhouette, not just the color.
- One bold mark, one accent pop allowed. Still no thin strokes, no text (a single-letter monogram is the exception), and it must read at 16 px and 70 px.
- The platform's canonical domain-to-hue palette lives in the server's favicon design guide; use the bright half of each pair as the dominant color.

**Asset set for origin-mode PWA installs** (skip for embed-only apps): `public/icon-192.png`, `public/icon-512.png`, `public/icon-512-maskable.png` (keep the mark inside the central 80% safe zone), `public/apple-touch-icon.png` (180 px, opaque), and `public/manifest.webmanifest` listing them with `purpose: "any"` / `"maskable"`, plus `<link rel="manifest">` and `<meta name="theme-color">` in `index.html`. Render every PNG from the SVG so they match; never draw them separately.
