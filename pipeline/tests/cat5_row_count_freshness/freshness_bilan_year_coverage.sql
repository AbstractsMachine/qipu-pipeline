{{ config(tags=['row_count_freshness']) }}
{{ assert_year_coverage('core_bilan_comptable', 'annee', [2019, 2020, 2021, 2022, 2023, 2024, 2025]) }}
