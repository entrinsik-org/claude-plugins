# App Templates

## Minimal Starter

### index.html
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div id="app">
        <h1>App Title</h1>
        <div id="content"></div>
    </div>
    <script type="module" src="main.js"></script>
</body>
</html>
```

### styles.css
```css
* { box-sizing: border-box; margin: 0; padding: 0; }

body {
    font-family: system-ui, sans-serif;
    background: #0f172a;
    color: #f1f5f9;
    padding: 24px;
}

#app {
    max-width: 1200px;
    margin: 0 auto;
}

h1 {
    font-size: 24px;
    margin-bottom: 24px;
}
```

### main.js
```javascript
window.informerReady = false;

async function init() {
    // List available datasets
    const datasets = await fetch('/api/datasets-list').then(r => r.json());
    console.log('Available datasets:', datasets);

    // Query a dataset
    if (datasets.length > 0) {
        const result = await fetch(`/api/datasets/${datasets[0].id}/_search`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: { match_all: {} }, size: 10 })
        }).then(r => r.json());

        const records = result.hits.hits.map(h => h._source);
        console.log('Records:', records);

        // Render your content here
        document.getElementById('content').innerHTML = `
            <p>Found ${result.hits.total} records</p>
            <pre>${JSON.stringify(records, null, 2)}</pre>
        `;
    }

    window.informerReady = true;
}

init();
```

## Dashboard Layout

### index.html
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div class="dashboard">
        <header>
            <h1>Dashboard Title</h1>
            <p class="subtitle">Description of this dashboard</p>
        </header>

        <div class="metrics">
            <div class="metric-card">
                <span class="metric-value" id="metric1">--</span>
                <span class="metric-label">Metric 1</span>
            </div>
            <div class="metric-card">
                <span class="metric-value" id="metric2">--</span>
                <span class="metric-label">Metric 2</span>
            </div>
            <div class="metric-card">
                <span class="metric-value" id="metric3">--</span>
                <span class="metric-label">Metric 3</span>
            </div>
            <div class="metric-card">
                <span class="metric-value" id="metric4">--</span>
                <span class="metric-label">Metric 4</span>
            </div>
        </div>

        <div class="content">
            <!-- Add your charts, tables, or other visualizations here -->
            <div id="visualization"></div>
        </div>
    </div>

    <script type="module" src="main.js"></script>
</body>
</html>
```

### styles.css
```css
* { box-sizing: border-box; margin: 0; padding: 0; }

:root {
    --bg: #0f172a;
    --bg-card: #1e293b;
    --border: #334155;
    --text: #f1f5f9;
    --text-muted: #94a3b8;
    --primary: #6366f1;
}

body {
    font-family: system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
}

.dashboard {
    max-width: 1400px;
    margin: 0 auto;
    padding: 32px 24px;
}

header {
    margin-bottom: 32px;
}

header h1 {
    font-size: 28px;
    font-weight: 700;
}

.subtitle {
    color: var(--text-muted);
    margin-top: 4px;
}

.metrics {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
    margin-bottom: 24px;
}

.metric-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    text-align: center;
}

.metric-value {
    display: block;
    font-size: 32px;
    font-weight: 700;
    color: var(--primary);
}

.metric-label {
    display: block;
    font-size: 13px;
    color: var(--text-muted);
    margin-top: 4px;
}

.content {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 24px;
}

@media (max-width: 768px) {
    .metrics { grid-template-columns: repeat(2, 1fr); }
}

@media (max-width: 480px) {
    .metrics { grid-template-columns: 1fr; }
}
```

### main.js
```javascript
window.informerReady = false;

async function init() {
    try {
        await loadData();
        window.informerReady = true;
    } catch (err) {
        console.error('Failed to load:', err);
    }
}

async function loadData() {
    // Replace with your dataset ID
    const datasetId = 'admin:your-dataset';

    const result = await fetch(`/api/datasets/${datasetId}/_search`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            query: { match_all: {} },
            size: 0,
            aggs: {
                total: { sum: { field: 'amount' } },
                count: { value_count: { field: 'id' } },
                avg: { avg: { field: 'amount' } },
                by_category: {
                    terms: { field: 'category', size: 10 },
                    aggs: { total: { sum: { field: 'amount' } } }
                }
            }
        })
    }).then(r => r.json());

    // Update metrics
    const aggs = result.aggregations;
    document.getElementById('metric1').textContent = formatCurrency(aggs.total.value);
    document.getElementById('metric2').textContent = aggs.count.value.toLocaleString();
    document.getElementById('metric3').textContent = formatCurrency(aggs.avg.value);
    document.getElementById('metric4').textContent = result.hits.total.toLocaleString();

    // Use aggs.by_category.buckets for visualization
    // Each bucket has: { key: 'Category Name', doc_count: 123, total: { value: 456 } }
    console.log('Category data:', aggs.by_category.buckets);
}

function formatCurrency(val) {
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 0
    }).format(val);
}

init();
```

## PDF Export Tips

The PDF renderer uses **print media** and adds a `.print` class to `<html>`.

```css
/* Standard @media print works */
@media print {
    body {
        background: white;
        color: black;
    }

    .no-print {
        display: none;
    }

    /* Avoid page breaks inside charts/cards */
    .chart-container,
    .metric-card {
        break-inside: avoid;
    }
}

/* Or use the .print class */
.print .no-print {
    display: none;
}
```
