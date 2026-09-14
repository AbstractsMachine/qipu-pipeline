# Qipu pipeline

The data pipeline behind **Qipu**: the transforms and tests that turn raw public
financial data into the figures published on the site.

It exists so anyone can check those figures. Start from the same public sources,
run the same transformations, run the same tests, get the same numbers.

## What's in it

- **Source ingestion** (`pipeline/scripts/sync/`) — how each dataset is fetched
  from its official open-data portal into the raw layer.
- **Transformations** (`pipeline/models/`) — a dbt project, `staging → core →
  marts`, row-level and auditable at every layer.
- **Tests** (`pipeline/tests/`) — referential integrity, accounting balance,
  freshness, completeness, cross-layer and anomaly checks.

178 models, 747 tests, 85 seeds, 80 sources.

## The figures

The published figures are the **marts**. They are publicly queryable in BigQuery
(the `dbt_paris_*` datasets under project `open-data-france-484717`), so you can
rebuild them from source and diff your tables against the ones the site reads.

See **[REPRODUCE.md](REPRODUCE.md)** for the step-by-step replay.

## Data sources

Everything derives from official open-data portals — Paris Open Data,
`data.economie.gouv.fr`/DECP, DGFiP, and the equivalent portals for the other
covered cities. Exact dataset references are declared in the dbt `sources` and
in each ingestion script.

## License

**MIT License** — free to use, modify and redistribute, including for commercial
purposes, as long as the copyright notice and the license text are kept. See
[LICENSE](LICENSE) and [NOTICE](NOTICE).
