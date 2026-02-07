# API Quick Reference

All endpoints are relative to `/api`. The Vite plugin handles authentication in dev mode.

## Datasets

### GET /api/datasets-list
List all datasets the user can access.

```javascript
const datasets = await fetch('/api/datasets-list').then(r => r.json());
// [{ id, name, description, records, size, tags, sharing }, ...]
```

### POST /api/datasets/{id}/_search
Query dataset data using Elasticsearch DSL.

```javascript
const result = await fetch(`/api/datasets/${id}/_search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        query: { match_all: {} },
        size: 100,
        from: 0,
        _source: ['field1', 'field2'],
        sort: [{ field1: 'desc' }],
        aggs: { total: { sum: { field: 'amount' } } }
    })
}).then(r => r.json());

// result.hits.total - count
// result.hits.hits - [{ _source: { ... } }, ...]
// result.aggregations - { total: { value: 12345 } }
```

**Query patterns:**
```javascript
// All records
{ query: { match_all: {} } }

// Exact match
{ query: { bool: { filter: [{ term: { status: 'active' } }] } } }

// Range
{ query: { bool: { filter: [{ range: { amount: { gte: 1000 } } }] } } }

// Date range
{ query: { bool: { filter: [{ range: { date: { gte: '2024-01-01', lte: '2024-12-31' } } }] } } }

// Multiple filters
{ query: { bool: { filter: [
    { term: { region: 'North' } },
    { range: { amount: { gte: 1000 } } }
] } } }

// Text search
{ query: { bool: { must: [{ match: { name: 'search text' } }] } } }
```

**Aggregation patterns:**
```javascript
// Metrics
{ aggs: { total: { sum: { field: 'amount' } } } }
{ aggs: { average: { avg: { field: 'amount' } } } }
{ aggs: { minimum: { min: { field: 'amount' } } } }
{ aggs: { maximum: { max: { field: 'amount' } } } }
{ aggs: { count: { value_count: { field: 'id' } } } }
{ aggs: { unique: { cardinality: { field: 'customer' } } } }

// Group by
{ aggs: { by_status: { terms: { field: 'status', size: 50 } } } }

// Group with metric
{ aggs: {
    by_region: {
        terms: { field: 'region', size: 50 },
        aggs: { total: { sum: { field: 'amount' } } }
    }
} }

// Date histogram
{ aggs: {
    by_month: {
        date_histogram: { field: 'date', calendar_interval: 'month' },
        aggs: { total: { sum: { field: 'amount' } } }
    }
} }
```

## Queries

### GET /api/queries-list
List saved queries.

```javascript
const queries = await fetch('/api/queries-list').then(r => r.json());
// [{ id, name, description, tags, sharing }, ...]
```

### POST /api/queries/{id}/_execute
Execute a saved query.

```javascript
const result = await fetch(`/api/queries/${id}/_execute`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        parameters: { startDate: '2024-01-01' }
    })
}).then(r => r.json());
```

## Integrations

### GET /api/integrations
List configured integrations.

```javascript
const result = await fetch('/api/integrations').then(r => r.json());
// result.items = [{ id, name, slug, type, description }, ...]
```

### POST /api/integrations/{id}/request
Make an authenticated request through an integration.

```javascript
const result = await fetch(`/api/integrations/${slugOrId}/request`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/path/to/endpoint',
        method: 'GET',              // GET, POST, PUT, PATCH, DELETE
        params: { key: 'value' },   // Query parameters
        data: { key: 'value' },     // Request body (POST/PUT/PATCH)
        headers: {}                 // Additional headers
    })
}).then(r => r.json());

// result.status - HTTP status
// result.data - Response body
// result.error - true if error status
```

**Salesforce examples:**

```javascript
// SOQL query
await fetch('/api/integrations/salesforce/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/data/v59.0/query',
        method: 'GET',
        params: { q: "SELECT Id, Name FROM Account LIMIT 10" }
    })
});

// Get record
await fetch('/api/integrations/salesforce/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/data/v59.0/sobjects/Account/001xxxxxxxxxxxx',
        method: 'GET'
    })
});

// Create record
await fetch('/api/integrations/salesforce/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/data/v59.0/sobjects/Contact',
        method: 'POST',
        data: { FirstName: 'John', LastName: 'Doe', Email: 'john@example.com' }
    })
});
```

## Data Access Configuration

Create `data-access.yaml` in your project root to declare which APIs your report needs. Without this file, all API access is blocked when published.

```yaml
# data-access.yaml

datasets:
  - admin:sales-data

queries:
  - admin:summary

integrations:
  - salesforce
```

### Row-Level Security

```yaml
datasets:
  - id: admin:orders
    filter:
      region: $user.custom.region
      owner: $user.username
```

### Integration Credentials

```yaml
integrations:
  - id: partner-api
    headers:
      Authorization: Bearer $user.custom.apiToken
    params:
      tenant: $tenant.id
```

### Variables

- `$user.username`, `$user.email`, `$user.displayName`
- `$user.custom.xxx` - Custom user fields
- `$tenant.id`
- `$report.id`, `$report.name`

## Error Handling

API errors return:
```javascript
{
    statusCode: 400,
    error: 'Bad Request',
    message: 'Description of error'
}
```

Common status codes:
- `400` - Bad request / validation error
- `401` - Not authenticated
- `403` - Not authorized
- `404` - Not found
- `502` - Upstream error (integration request failed)
