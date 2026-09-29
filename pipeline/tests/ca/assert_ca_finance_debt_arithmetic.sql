-- The debt table's own arithmetic holds each year: debenture debt less
-- internally held = externally held; externally held less sinking fund = net.
WITH d AS (
    SELECT fiscal_year,
           SUM(IF(line_key = 'debenturedebtoutstanding', value_as_printed, 0)) AS debenture,
           SUM(IF(line_key = 'lessinternallyhelddebt', value_as_printed, 0))   AS internal_neg,
           SUM(IF(line_key = 'externallyhelddebt', value_as_printed, 0))       AS external,
           SUM(IF(line_key = 'lesssinkingfundreserves', value_as_printed, 0))  AS sinking,
           SUM(IF(line_key = 'netexternallyhelddebt', value_as_printed, 0))    AS net
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    WHERE table_name = 'debt'
    GROUP BY 1
)
SELECT * FROM d
WHERE ABS(debenture + internal_neg - external) > 2 OR ABS(external - sinking - net) > 2
