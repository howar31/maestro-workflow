# Frontend reference

Patterns and templates for `/maestro.web.frontend.spec`. Read once before
elaborating a feature's frontend section.

## Stack discovery

Detect the stack from the project root before writing anything:

| Signal | Likely stack |
|--------|--------------|
| `package.json` has `react`, `next`, `vite` + `react` | React (CSR/SSR) |
| `package.json` has `vue`, `nuxt` | Vue |
| `package.json` has `svelte`, `sveltekit` | Svelte |
| `package.json` has `solid-js` | Solid |
| `astro.config.mjs` | Astro (multi-island) |
| `app.json` + `react-native` | React Native |

Detect language: `tsconfig.json` → TypeScript; `jsconfig.json` or no tsconfig → JS.

Detect styling: `tailwind.config.*` / `postcss.config.*` / CSS modules / styled-components / vanilla CSS.

Detect routing: file-based (Next/Nuxt/SvelteKit) vs explicit (`react-router`, `vue-router`).

If stack is ambiguous, **ask the user** — do not guess.

## Component structure

For each new screen / non-trivial component, the spec must answer:

- **Component tree** — parent/children, with one-line responsibility per node.
- **State location** — local (useState/ref) vs lifted vs global (zustand/redux/pinia/jotai vs context). Justify the choice.
- **Data flow** — props down, callbacks up; or via context / store. Avoid prop drilling > 3 levels.
- **Async surface** — what triggers fetches (mount, user action, route change), what shows loading / error / empty states.
- **Form state** (if applicable) — controlled vs uncontrolled; validation library; submission flow.
- **Side effects** — useEffect / watchEffect / onMount; cleanup; idempotency.

## Accessibility (a11y) — non-negotiable section

Every spec must include this checklist, populated:

- **Semantic HTML** — landmarks (`<main>`, `<nav>`, `<header>`), heading hierarchy.
- **Keyboard navigation** — tab order, focus visible, Escape to dismiss modals.
- **ARIA** — only when semantic HTML is insufficient; never as decoration.
- **Forms** — `<label for>` association, error associated via `aria-describedby`, required/invalid via `aria-required`/`aria-invalid`.
- **Color** — contrast ratio ≥ 4.5:1 for body text, ≥ 3:1 for large text. Never colour-only signals.
- **Motion** — respect `prefers-reduced-motion`.
- **Live regions** — `aria-live="polite"` for non-critical updates, `assertive` for errors that demand attention.
- **Screen reader testing** — at minimum VoiceOver (mac) or NVDA (Win); document the flow tested.

If the spec author cannot answer one of these, flag it as **OPEN** in the
spec — do not omit.

## Routing & data loading

- Document each route or screen entry point.
- For Next/Nuxt/SvelteKit, decide between server / client / static rendering per route. Justify.
- Document data dependencies per route: what API calls, expected response shape, error handling, caching policy (SWR / React Query / built-in).
- Document SEO requirements: meta tags, OG tags, canonical, structured data (if applicable).

## State management

When introducing a global store, the spec must answer:

- What state is global vs local?
- Why not local? (avoid premature globalisation)
- Selectors / derived state pattern.
- Persistence (sessionStorage / localStorage / cookies)? Hydration concerns?
- Reset / logout behaviour?

## Performance budget

Set explicit budgets:

- **Initial JS** — KB after gzip (target depends on app: e.g. ≤ 200 KB for marketing, ≤ 500 KB for app shells).
- **LCP / INP / CLS** — Core Web Vitals targets (LCP < 2.5s, INP < 200ms, CLS < 0.1).
- **Bundle splits** — code-split per route.
- **Images** — AVIF/WebP, lazy load below-fold, explicit width/height to prevent CLS.

## Test plan

Three layers, all required for non-trivial features:

1. **Unit** — pure logic, hooks (testing-library), utility functions.
2. **Component** — render + user interaction (testing-library + jsdom or Vue Test Utils).
3. **E2E** — Playwright. The spec must include the Playwright recipe.

### Playwright e2e template

```typescript
// tests/e2e/<feature>.spec.ts
import { test, expect } from '@playwright/test';

test.describe('<feature name>', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/<entry-route>');
  });

  test('happy path: <user goal>', async ({ page }) => {
    // arrange
    await page.getByRole('textbox', { name: /<label>/i }).fill('<input>');

    // act
    await page.getByRole('button', { name: /<button label>/i }).click();

    // assert
    await expect(page.getByText(/<success indicator>/i)).toBeVisible();
  });

  test('error: <failure scenario>', async ({ page }) => {
    // ...
  });

  test('a11y: keyboard-only flow', async ({ page }) => {
    await page.keyboard.press('Tab');
    await expect(page.locator(':focus')).toBeVisible();
    // ... drive entire happy path via keyboard
  });
});
```

Recipe to run: `pnpm playwright test tests/e2e/<feature>.spec.ts`.

## File layout heuristics

- One component per file (`button.tsx`, not a monolithic `forms.tsx`).
- Co-locate styles when CSS modules or styled-components.
- Tests sit next to source (`button.test.tsx`) OR in `__tests__/` — match the project's existing convention.
- Avoid barrel files (`index.ts` re-exporting everything) unless the project already uses them — they hurt tree-shaking.

## Common anti-patterns to flag

- ❌ Spreading props without enumerating expected ones (`<X {...props}>` in
  reusable components hides API).
- ❌ `useEffect` for derived state (use `useMemo` / computed instead).
- ❌ Fetch-on-mount without abort handling on unmount.
- ❌ `dangerouslySetInnerHTML` / `v-html` with user-provided content (XSS).
- ❌ Hardcoded inline strings — use i18n if the project supports more than one locale.
- ❌ Skipping the loading state ("optimistic UI" without a fallback).

## Deliverable

`/maestro.web.frontend.spec` should append to (or create) the sprint's
SPEC.md a **Frontend** section structured as:

```markdown
## Frontend

### Stack
<detected, confirmed with user>

### Component tree
<diagram or nested list>

### State & data flow
...

### Accessibility checklist
...

### Routing & data loading
...

### Performance budget
...

### Test plan
- Unit: ...
- Component: ...
- E2E: tests/e2e/<feature>.spec.ts (recipe above)

### Open questions
- ...
```

Plus, when applicable, scaffold `tests/e2e/<feature>.spec.ts` with the
template above (only the structure — actual selectors and assertions are
the developer's job during `/maestro.work`).
