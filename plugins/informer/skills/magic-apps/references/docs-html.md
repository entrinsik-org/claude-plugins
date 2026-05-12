# App Documentation (`docs.html`)

> **Load this reference when:** adding in-gallery documentation to an app — `docs.html` in `public/`, the in-app `?` help button pattern, structure/style guidance, or the `README.md` fallback.
>
> **Not in this file:** the app's `favicon.svg` gallery icon — see SKILL.md "App Icon". Widget documentation (each widget is self-contained) — see `widgets.md`.

Apps can include documentation that's accessible directly from the app gallery. Place a `docs.html` file in your `public/` directory — it's deployed to the library root alongside `favicon.svg` and `informer.yaml`.

**Priority:** `docs.html` > `README.md`. If both exist, `docs.html` is used. `README.md` is the fallback for quick-and-simple docs (rendered as markdown in a dialog).

## Gallery Integration

When an app has documentation, a small book icon badge appears on the app card in the gallery. Clicking the badge opens the docs in a dialog without launching the app — great for usage guides, data dictionaries, onboarding flows, or release notes.

## In-App Help Button

Since apps run in a chromeless window (no browser toolbar), consider adding a `?` help button in the top-right corner of your app that opens the documentation inline. This gives users quick access to help without leaving the app.

```javascript
// Simple help button that opens docs.html in a modal
const helpBtn = document.createElement('button');
helpBtn.textContent = '?';
Object.assign(helpBtn.style, {
    position: 'fixed', top: '12px', right: '12px', zIndex: '9999',
    width: '32px', height: '32px', borderRadius: '50%',
    border: 'none', cursor: 'pointer',
    background: 'rgba(128,128,128,0.15)', color: 'inherit',
    fontSize: '16px', fontWeight: '600',
    backdropFilter: 'blur(8px)',
    transition: 'background 0.15s ease',
});
helpBtn.addEventListener('mouseenter', () => helpBtn.style.background = 'rgba(128,128,128,0.25)');
helpBtn.addEventListener('mouseleave', () => helpBtn.style.background = 'rgba(128,128,128,0.15)');
helpBtn.addEventListener('click', () => {
    // Open docs.html in a centered modal iframe
    const overlay = document.createElement('div');
    Object.assign(overlay.style, {
        position: 'fixed', inset: '0', zIndex: '10000',
        background: 'rgba(0,0,0,0.5)', display: 'flex',
        alignItems: 'center', justifyContent: 'center',
    });
    overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });

    const frame = document.createElement('iframe');
    frame.src = 'docs.html';
    Object.assign(frame.style, {
        width: '90vw', maxWidth: '900px', height: '80vh',
        border: 'none', borderRadius: '12px',
        boxShadow: '0 24px 80px rgba(0,0,0,0.3)',
    });
    overlay.appendChild(frame);
    document.body.appendChild(overlay);
});
document.body.appendChild(helpBtn);
```

## Writing Great `docs.html`

Since `docs.html` is a full HTML page, you have complete creative control. Make it engaging and visually match the app's design. A good docs page should feel like part of the app, not an afterthought.

**Structure:**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App Name — Documentation</title>
    <style>
        /* Match your app's design system */
    </style>
</head>
<body>
    <header>
        <h1>App Name</h1>
        <p class="subtitle">What it does in one line</p>
    </header>

    <nav>
        <!-- Quick jump links for longer docs -->
    </nav>

    <main>
        <section id="getting-started">...</section>
        <section id="features">...</section>
        <section id="data-dictionary">...</section>
    </main>
</body>
</html>
```

**Best practices:**

- **Self-contained** — inline all styles. No external CSS/JS dependencies (the file is served from the library root)
- **Responsive** — the docs dialog can be narrow on mobile. Use fluid widths
- **Theme-aware** — respect `prefers-color-scheme` so docs look good in both light and dark mode:
  ```css
  :root { --bg: #fff; --text: #1a1a1a; --muted: #666; --border: #e5e5e5; --accent: #2563eb; }
  @media (prefers-color-scheme: dark) {
      :root { --bg: #1a1a2e; --text: #e0e0e0; --muted: #999; --border: #333; --accent: #60a5fa; }
  }
  body { background: var(--bg); color: var(--text); }
  ```
- **Include visuals** — screenshots, diagrams, or annotated UI mockups help users understand at a glance. Use inline SVG or base64 images to stay self-contained
- **Data dictionary** — if your app works with specific fields/columns, include a table explaining what each one means
- **Keyboard shortcuts** — if your app has any, list them in a clean table
- **Version/changelog** — a brief "What's New" section helps returning users

## `README.md` Fallback

For simpler docs, place a `README.md` in `public/`. It's rendered as markdown in the gallery dialog. Good for quick descriptions, but `docs.html` is preferred for anything with structure or style.

## Project Structure with Docs

```
my-app/
  public/
    favicon.svg           ← App icon
    docs.html             ← App documentation (preferred)
  migrations/
    001-create-tables.sql
  server/
    orders/index.js
  src/
    main.js
  informer.yaml
  index.html
  package.json
```
