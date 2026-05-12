# Widgets

> **Load this reference when:** declaring widgets in `informer.yaml`, building self-contained HTML files under `public/widgets/`, working around iframe constraints (no tooltip overflow, no external stylesheets), or wiring widget data access through server routes (Pattern A is strongly preferred for widgets — see "Data Access" below).
>
> **Not in this file:** the main app shell — see SKILL.md "Bootstrapping". Server route handlers that widgets call — see `server-routes.md`. The Pattern A/B/C decision flow for dep access — see SKILL.md "Accessing Your Dependencies".

Apps can expose **widgets** — small, self-contained HTML cards that render inside Informer's widget gallery. Widgets are ideal for at-a-glance KPIs, sparkline charts, status indicators, and compact data visualizations that users can pin to their home screen.

## How Widgets Work

Widgets are static HTML files in your `public/widgets/` directory, declared in `informer.yaml`. They render inside **iframes** at fixed grid sizes, fetch data using the same APIs as the main app, and auto-refresh on a configurable interval.

## Declaring Widgets in `informer.yaml`

Add a `widgets:` section alongside your `dependencies:` and `roles:` sections:

```yaml
# informer.yaml
dependencies:
  quickbooks:
    target: integration
    defaultBinding: quickbooks-assistant-skill

widgets:
  cash-balance:
    entry: widgets/cash-balance.html
    label: Cash Balance
    size: { w: 2, h: 1 }
    refresh: 300
  sales-trend:
    entry: widgets/sales-trend.html
    label: Sales Trend
    size: { w: 2, h: 2 }
    refresh: 300
```

| Field | Description |
|-------|-------------|
| `entry` | Path to the HTML file relative to `public/` |
| `label` | Display name shown in the widget gallery |
| `size` | Grid dimensions — `w` (width) and `h` (height) in grid units. Common sizes: `{ w: 2, h: 1 }` (standard card), `{ w: 2, h: 2 }` (tall card) |
| `refresh` | Auto-refresh interval in seconds (e.g. `300` = 5 minutes) |

## Widget HTML Structure

Each widget is a **fully self-contained HTML file** — all CSS and JS inline, no npm imports, no build step. They're served as static files from `public/`.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Widget Name</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }

:root {
    --bg: #ffffff;
    --text: #1a1a1a;
    --muted: #71717A;
}
[data-theme="dark"] {
    --bg: #131316;
    --text: #FAFAFA;
    --muted: #71717A;
}

html, body {
    height: 100%;
    overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    -webkit-font-smoothing: antialiased;
    background: var(--bg);
    color: var(--text);
}

/* Loading state */
.loading {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
}
.dot {
    width: 4px; height: 4px;
    border-radius: 50%;
    background: var(--muted);
    animation: pulse 1.2s ease-in-out infinite;
    margin: 0 3px;
}
.dot:nth-child(2) { animation-delay: 0.15s; }
.dot:nth-child(3) { animation-delay: 0.3s; }
@keyframes pulse {
    0%, 100% { opacity: 0.3; }
    50% { opacity: 1; }
}

/* Error state */
.error {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    font-size: 11px;
    color: var(--muted);
}

/* Ready state */
.ready { animation: fadeIn 0.4s ease-out; }
@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
</style>
</head>
<body>
<script>
(function () {
    // 1. Apply theme
    const theme = window.__INFORMER__?.theme || 'light';
    document.documentElement.setAttribute('data-theme', theme);

    // 2. Show loading
    document.body.innerHTML = '<div class="loading"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>';

    // 3. Fetch data via a server route — the route uses
    //    context.<slot>.request(...) to talk to the bound integration.
    //    Widget code never sees the integration UUID or slug, so
    //    installer rebinds don't break this widget. See SKILL.md
    //    "Accessing Your Dependencies" for the three patterns.
    fetch('/api/_server/widget/balance')
    .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(data => {
        document.body.innerHTML = '<div class="ready"><!-- your content --></div>';
    })
    .catch(() => {
        document.body.innerHTML = '<div class="error">Unable to load</div>';
    });
})();
</script>
</body>
</html>
```

## Key Patterns

**Theme support:** Always read `window.__INFORMER__?.theme` and set `data-theme` on `<html>`. Define CSS custom properties for both light and dark modes.

**Three states:** Every widget should handle loading (animated dots), error ("Unable to load"), and ready (fade-in content).

**Layout approach:** Use `position: absolute` for background elements (charts, bars) and a `position: relative; z-index: 1` content overlay for text. This layers text over decorative visuals cleanly.

```css
/* Background chart behind content */
.chart {
    position: absolute;
    bottom: 0; left: 0; right: 0;
    height: 60%;
    overflow: hidden;
}

/* Text content overlaid on top */
.content {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 14px 16px 10px;
    pointer-events: none; /* let clicks pass through to chart if needed */
}
```

**SVG charts without libraries:** Widgets should not import charting libraries. Use inline SVG with Catmull-Rom spline interpolation for smooth area/line charts:

```javascript
function catmullRom(pts) {
    if (pts.length < 2) return '';
    if (pts.length === 2) return `M${pts[0].x},${pts[0].y}L${pts[1].x},${pts[1].y}`;
    let d = `M${pts[0].x},${pts[0].y}`;
    for (let i = 0; i < pts.length - 1; i++) {
        const p0 = pts[Math.max(i - 1, 0)], p1 = pts[i];
        const p2 = pts[i + 1], p3 = pts[Math.min(i + 2, pts.length - 1)];
        const t = 6; // tension
        d += `C${(p1.x + (p2.x - p0.x) / t).toFixed(1)},${(p1.y + (p2.y - p0.y) / t).toFixed(1)} ` +
             `${(p2.x - (p3.x - p1.x) / t).toFixed(1)},${(p2.y - (p3.y - p1.y) / t).toFixed(1)} ` +
             `${p2.x.toFixed(1)},${p2.y.toFixed(1)}`;
    }
    return d;
}

// Area chart: close the path along the bottom
const linePath = catmullRom(points);
const areaPath = linePath + `L${W},${H}L0,${H}Z`;
```

**Iframe constraints:** Widgets render in iframes, which means:
- **No overflow tooltips** — CSS tooltips positioned outside the widget bounds are clipped. Use `title` attributes for native browser tooltips, or swap content inline on hover (e.g. replace a legend row with detail on `mouseenter`).
- **No external stylesheets** — everything must be inline.
- **No shared state** — each widget is isolated. Fetch its own data.

**Hover interactions:** Use dim-siblings patterns for bar charts and distribution charts:

```css
.bars:hover .bar { opacity: 0.35; }
.bars:hover .bar:hover { opacity: 1; }
```

For hover detail that replaces a legend:

```javascript
bar.addEventListener('mouseenter', () => {
    legend.style.display = 'none';
    detail.style.display = 'flex';
    detailLabel.textContent = bar.dataset.label;
    detailAmount.textContent = bar.dataset.amount;
});
barsContainer.addEventListener('mouseleave', () => {
    legend.style.display = 'flex';
    detail.style.display = 'none';
});
```

**Interactive controls:** Widgets can include `<select>` dropdowns or simple controls for filtering. Use a reactive render pattern — fetch data once, store in memory, re-render on filter change:

```javascript
function render(filter) {
    // Recompute from cached data
    // Update DOM elements by ID
}

document.getElementById('picker').addEventListener('change', function() {
    render(this.value || null);
});

render(null); // initial render
```

## Data Access

Widgets are frontend code — same runtime as the main app's browser-side code. They access deps via the same three patterns documented in SKILL.md "Accessing Your Dependencies":

```javascript
// Pattern A (preferred) — call a server route that uses context.<slot>
fetch('/api/_server/widget/cash-balance')
    .then(r => r.json())
    .then(({ balance }) => { /* render */ });

// Pattern B (acceptable for SPA widgets) — runtime binding discovery
// Requires `access.apis: [GET /api/apps/*/dependencies]` in informer.yaml
const appId = window.__INFORMER__.report.id;
const { items } = await fetch(`/api/apps/${appId}/dependencies`).then(r => r.json());
const orderDatasetId = items.find(i => i.name === 'orders').targetId;
const hits = await fetch(`/api/datasets/${orderDatasetId}/_search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: { match_all: {} }, size: 100 })
}).then(r => r.json());

// Pattern C (DO NOT) — hardcoded UUID or configId in the URL
// fetch('/api/datasets/admin:sales-data/_search', ...)   ← breaks on rebind
// fetch('/api/datasets/7d5a9b1e-.../_search', ...)        ← same problem
```

Widgets generally benefit from Pattern A even more than the main app does: each widget is small, rendered in an iframe, and gets re-loaded on every refresh — the extra round-trip for Pattern B's runtime discovery shows up visibly. A server route that pre-aggregates and returns just the metric the widget displays is usually the right shape.

## Project Structure with Widgets

```
my-app/
  public/
    favicon.svg
    widgets/
      cash-balance.html       ← Widget: 2×1 KPI card
      sales-trend.html        ← Widget: 2×2 chart card
      aged-receivables.html   ← Widget: 2×1 bar chart
  src/
    main.js                   ← Main app entry point
  server/
    stats/index.js            ← Server route (shared by app + widgets)
  migrations/
    001-create-tables.sql
  informer.yaml               ← Declares access, widgets, roles
  index.html
  package.json
```
