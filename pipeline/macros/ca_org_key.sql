{#
  Organisation key for Vancouver's registers (SOFI payees ↔ contract vendors).
  The SOFI prints one organisation under several spellings across 15 years
  ("Municipal Pension Plan Province Of BC" / "Municipal Pension Plan Prov. of
  BC"; "Greater Vanc. Water District"; "Scott Special Projects Ltd."). The key:
    lower case, "&" → "and", abbreviations the schedules use written out
    (vanc / "van." → vancouver — "Van" without a period is a surname, kept —,
    prov → province, gen → general, and rec → receiver ONLY before "gen" or
    "of": "Rec. Gen'l" is the Receiver General, "Rec. of Millennium Southeast"
    a receiver, but "Roundhouse Community Arts & Rec Society" is recreation
    and "Chrysalis … Abuse Rec. Soc" recovery — "rec" anywhere else is kept
    as printed, since nothing says which word it cut), a leading "the" and
    trailing legal forms dropped (ltd, limited, inc, incorporated, corp,
    corporation, co, "& co", company, llp, lp, ulc),
    every other run of non-alphanumerics → "-".
  Nothing fuzzy: two names share a key only when they are the same words.
#}
{% macro ca_org_key(col) -%}
REGEXP_REPLACE(
  REGEXP_REPLACE(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(
              REGEXP_REPLACE(LOWER(TRIM({{ col }})), r'&', ' and '),
            r'\bvanc\b\.?|\bvan\.', 'vancouver '),
          r'\bprov\b\.?', 'province'),
        r'\brec\b\.?\s*(gen|of\b)', r'receiver \1'),
      r'\bgen\b\.?', 'general'),
    r'^\s*the\s+', ''),
  r'[^a-z0-9]+', '-'),
r'^-+|(-(and-co|ltd|limited|inc|incorporated|corp|corporation|co|company|llp|lp|ulc))*-*$', '')
{%- endmacro %}
