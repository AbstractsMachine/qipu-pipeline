# Qipu pipeline

The data pipeline behind [qipu.org](https://www.qipu.org): the transforms and tests that turn public financial data
into the figures published on the site.

It exists so anyone can check those figures. Start from the same public sources, run the same transformations and the
same tests, and you get the same numbers.

Code: AGPL-3.0, data: the licence of each source (see [NOTICE](NOTICE)).

## How it fits together

```
official open-data portals ──▶ pipeline/scripts/sync/ ──▶ BigQuery raw tables
(Paris, Marseille, data.gouv,                                  │
 DGFiP, DECP, San Francisco,                                   ▼
 Vancouver, Brazil's PNCP ...)       pipeline/models/: staging ──▶ core ──▶ marts ──▶ the site
                                     pipeline/seeds/: reference tables and frozen caches
                                     pipeline/tests/: checks between and across the layers
```

- **Ingestion** (`pipeline/scripts/sync/`): one script per source fetches a dataset from its official portal into the raw
  layer. The source of each table is declared in the dbt `sources` files.
- **Transformations** (`pipeline/models/`): a [dbt](https://docs.getdbt.com/) project on BigQuery. `staging` cleans each
  source, `core` joins them into one row per budget line, contract or grant, and `marts` are the tables the site reads.
  Paris and the other French cities sit at the top of `models/`; `national/` holds the French national accounts, and
  `us/`, `ca/` and `br/` hold San Francisco, Vancouver and Brazil.
- **Seeds** (`pipeline/seeds/`): constants, mappings and official transcriptions, plus frozen outputs of a separate
  classification step. [NOTICE](NOTICE) says which.
- **Tests** (`pipeline/tests/`, and the tests declared next to the models): referential integrity, accounting balance,
  freshness, completeness, cross-layer and anomaly checks.

434 models, 1,123 tests, 116 seeds and 207 sources. CI prints these counts on every run.

## The figures

The published figures are the **marts**. They can be queried publicly in BigQuery (the `dbt_paris_*` datasets in project
`open-data-france-484717`), so you can rebuild them from source and compare your tables with the ones the site reads.

[REPRODUCE.md](REPRODUCE.md) gives the steps.

## Checks

CI runs offline, with no cloud credentials: it parses the dbt project (so every `ref` and `source` resolves), prints the
size of the graph and compiles every ingestion script. A full `dbt build` needs a BigQuery project and runs in yours, as
REPRODUCE.md describes.

## Licence

Code is under the **GNU Affero General Public License v3.0** (AGPL-3.0-only). You may use, modify and redistribute it.
If you distribute it, or run a modified version as a network service, you must make its source available under the same
licence. See [LICENSE](LICENSE).

Data keeps the licence and terms of its publishers. [NOTICE](NOTICE) lists what ships here and what does not.
