-- Privacy gate: no payee whose name was withheld (a name that could be a
-- person's) reaches the payees mart, which the website exports by name.
SELECT p.payee_key
FROM {{ ref('mart_ca_vancouver_payees') }} p
JOIN {{ ref('core_ca_vancouver_sofi_payments') }} c USING (payee_key)
WHERE c.payee_kind = 'withheld'
