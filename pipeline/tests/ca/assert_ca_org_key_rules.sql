-- The organisation key (macros/ca_org_key.sql) on names the schedules print.
-- Each row is a printed name and the key it must give; the test fails on any
-- row whose key differs. "Rec" is the case that broke (2026-09-23): the macro
-- wrote every "rec" out as "receiver", so the Roundhouse Community Arts & Rec
-- Society became "…-and-receiver-society". "rec" is the Receiver only before
-- "gen" or "of"; anywhere else it stays as printed.
WITH cases AS (
    SELECT * FROM UNNEST([
        STRUCT("Rec. Gen'l for Canada RCMP - GRC" AS printed, 'receiver-general-l-for-canada-rcmp-grc' AS expected),
        STRUCT('Rec. General of Cda Industry Canada', 'receiver-general-of-cda-industry-canada'),
        STRUCT('Rec. Gen. for Canada Industry Canada', 'receiver-general-for-canada-industry-canada'),
        STRUCT('Receiver General Of Canada', 'receiver-general-of-canada'),
        STRUCT('Ernst & Young Inc Rec. of Millennium Southeast', 'ernst-and-young-inc-receiver-of-millennium-southeast'),
        STRUCT('Roundhouse Community Arts & Rec Society', 'roundhouse-community-arts-and-rec-society'),
        STRUCT('Roundhouse Comm. Arts & Rec. Society', 'roundhouse-comm-arts-and-rec-society'),
        STRUCT('Chrysalis Drug and Alcohol Abuse Rec. Soc', 'chrysalis-drug-and-alcohol-abuse-rec-soc'),
        STRUCT('Hastings Community Rec Centre', 'hastings-community-rec-centre'),
        STRUCT('Greater Vanc. Water District', 'greater-vancouver-water-district'),
        STRUCT('Municipal Pension Plan Prov. of BC', 'municipal-pension-plan-province-of-bc'),
        STRUCT('Scott Special Projects Ltd.', 'scott-special-projects'),
        STRUCT('The Bloom Group', 'bloom-group'),
        STRUCT('Van Houtte Coffee Services Inc.', 'van-houtte-coffee-services')
    ])
)
SELECT printed, expected, {{ ca_org_key('printed') }} AS got
FROM cases
WHERE {{ ca_org_key('printed') }} != expected
