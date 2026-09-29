{#
  Country-namespaced dataset naming (ADR-0010 D3).

  Default dbt behaviour is kept for every Paris/France schema:
    prod  target.schema = dbt_paris           + 'staging' → dbt_paris_staging
    dev   target.schema = dbt_paris_dev_local + 'staging' → dbt_paris_dev_local_staging

  Custom schemas prefixed 'us_' land in the mirrored dbt_us_* family,
  preserving the dev/ci/prod isolation encoded in target.schema:
    prod  dbt_paris           + 'us_staging' → dbt_us_staging
    dev   dbt_paris_dev_local + 'us_staging' → dbt_us_dev_local_staging
    ci    dbt_paris_ci_42     + 'us_staging' → dbt_us_ci_42_staging

  Custom schemas prefixed 'br_' land in the mirrored dbt_br_* family
  (Recife — br-municipal), same dev/ci/prod isolation:
    prod  dbt_paris           + 'br_staging' → dbt_br_staging
    dev   dbt_paris_dev_local + 'br_staging' → dbt_br_dev_local_staging

  Custom schemas prefixed 'ca_' land in the mirrored dbt_ca_* family
  (Vancouver — ca-municipal), same dev/ci/prod isolation:
    prod  dbt_paris           + 'ca_staging' → dbt_ca_staging
    dev   dbt_paris_dev_local + 'ca_staging' → dbt_ca_dev_local_staging

  Any target.schema that does not carry the dbt_paris base falls back to
  the stock behaviour (no silent surprises on exotic targets).
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- elif custom_schema_name.strip().startswith('us_') and 'dbt_paris' in default_schema -%}
        {{ default_schema | replace('dbt_paris', 'dbt_us') }}_{{ custom_schema_name.strip()[3:] }}
    {%- elif custom_schema_name.strip().startswith('br_') and 'dbt_paris' in default_schema -%}
        {{ default_schema | replace('dbt_paris', 'dbt_br') }}_{{ custom_schema_name.strip()[3:] }}
    {%- elif custom_schema_name.strip().startswith('ca_') and 'dbt_paris' in default_schema -%}
        {{ default_schema | replace('dbt_paris', 'dbt_ca') }}_{{ custom_schema_name.strip()[3:] }}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
