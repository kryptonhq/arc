# Grafana dashboard

`arc-dashboard.json` is an importable Grafana dashboard over the metrics Arc exports at
`/metrics`: connections and churn, fan-out latency, the HTTP API, every rate limit and
authorisation failure, webhooks, and the BEAM runtime per node.

Import it with **Dashboards → New → Import**, upload the file, and pick your Prometheus
data source when asked. It works with any Prometheus-compatible store, including Grafana
Cloud fed by Alloy or a Prometheus agent; see the
[observability docs](../../website/content/docs/operations/observability.mdx) for scraping.

Variables at the top filter by scrape job, instance (node), and app id. Thresholds on the
fan-out, run-queue, rate-limit and webhook panels are the "look at this" lines from the
[high-availability runbook](../../website/content/docs/operations/high-availability.mdx).
