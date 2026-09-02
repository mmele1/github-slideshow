-- =====================================================================
-- 00_discovery_labels.sql
-- PURPOSE: Confirm the literal string values this analysis depends on
--          BEFORE running the full workflow. Run each block once, paste
--          the real values into the n8n "Normalize Request" node config.
-- COST:    Small. Each block scans <= 90 days of one table.
-- RUN IN:  BigQuery console (any project you can bill to).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOCK 1 -- Which wrap "Detailed Reason" values mark an escalation?
-- SOP says MC/CARE agents wrap escalations with Detailed Reason
-- "Escalated by Agent", and outcome codes for "Escalation Resolved by
-- Supervisor" / "Escalation Transferred to Tier II". Confirm the exact
-- strings as they land in the wrap PDT.
-- ---------------------------------------------------------------------
SELECT
  wrap_reason_detail,
  COUNT(*) AS wrap_count,
  COUNT(DISTINCT wrap_agent_id) AS agents,
  MIN(DATE(wrap_datetime)) AS first_seen,
  MAX(DATE(wrap_datetime)) AS last_seen
FROM `wf-gcp-us-service-data-prod.omnichannel_public.tbl_service_contact_wrap`
WHERE wrap_datetime >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND (
    LOWER(wrap_reason_detail) LIKE '%escalat%'
    OR LOWER(wrap_reason_detail) LIKE '%supervisor%'
    OR LOWER(wrap_reason_detail) LIKE '%tier%'
    OR LOWER(wrap_reason_detail) LIKE '%senior associate%'
  )
GROUP BY 1
ORDER BY wrap_count DESC;


-- ---------------------------------------------------------------------
-- BLOCK 2 -- What are the exact Genesys queue names for MC / CARE?
-- Genesys transfer guide lists "US Multi Contact" and
-- "Perigold CARE Escalations"; confirm every NA MC/CARE variant.
-- NOTE: wrap_compliance is a nested (ARRAY) column on this datamart.
--       If the UNNEST field names below error, run BLOCK 2b first.
-- ---------------------------------------------------------------------
SELECT
  wc.wrap_compliance_contact_queue_name AS queue_name,
  COUNT(*) AS rows_90d
FROM `wf-gcp-us-ae-gat-prod.ops_reporting.tbl_datamart_service_performance_metrics` t,
  UNNEST(t.wrap_compliance) AS wc
WHERE t.employee_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
  AND (
    LOWER(wc.wrap_compliance_contact_queue_name) LIKE '%multi%contact%'
    OR LOWER(wc.wrap_compliance_contact_queue_name) LIKE '%care%'
    OR LOWER(wc.wrap_compliance_contact_queue_name) LIKE '%escalat%'
  )
GROUP BY 1
ORDER BY rows_90d DESC;

-- BLOCK 2b -- Column names on the datamart (run if BLOCK 2 errors).
-- SELECT column_name, data_type
-- FROM `wf-gcp-us-ae-gat-prod.ops_reporting.INFORMATION_SCHEMA.COLUMNS`
-- WHERE table_name = 'tbl_datamart_service_performance_metrics'
-- ORDER BY ordinal_position;


-- ---------------------------------------------------------------------
-- BLOCK 3 -- How is the NA Multi-Contact team labelled on the roster?
-- Feeds the ROSTER_TEAM_PATTERNS parameter. Look for the MC / SpS
-- (Specialized Supervisor) team + workgroup strings in NA.
-- ---------------------------------------------------------------------
WITH latest_employee AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      e.*,
      ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY employee_date DESC) AS rn
    FROM `wf-gcp-us-ae-gat-prod.ops_reporting_core.tbl_snapshot_dim_employee` e
    WHERE employee_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
  ) WHERE rn = 1
)
SELECT
  employee_working_region,
  employee_working_team,
  employee_workgroup_name,
  employee_working_site,
  COUNT(*) AS headcount
FROM latest_employee
WHERE employee_is_in_customer_service_org_flag
  AND (
    LOWER(COALESCE(employee_working_team, ''))     LIKE '%multi%'
    OR LOWER(COALESCE(employee_workgroup_name, '')) LIKE '%multi%'
    OR LOWER(COALESCE(employee_working_team, ''))     LIKE '%care%'
    OR LOWER(COALESCE(employee_workgroup_name, '')) LIKE '%care%'
    OR LOWER(COALESCE(employee_working_team, ''))     LIKE '%specialized%'
  )
GROUP BY 1, 2, 3, 4
ORDER BY headcount DESC;


-- ---------------------------------------------------------------------
-- BLOCK 4 -- Transcript coverage: how many MC/CARE contacts actually
-- have a Level AI phone transcript we can analyze?
-- (Determines whether the qualitative sample is representative.)
-- ---------------------------------------------------------------------
SELECT
  DATE_TRUNC(DATE(l.ContactDateTime), MONTH) AS contact_month,
  COUNT(*)                                            AS lai_rows,
  COUNTIF(l.asr_log_id IS NOT NULL)                   AS with_asr_log,
  COUNTIF(l.banking_conversation_id IS NOT NULL)      AS with_levelai_convo
FROM `wf-gcp-us-ae-cs-prod.gsat_reporting.lai_pipeline_data` l
WHERE DATE(l.ContactDateTime) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
GROUP BY 1
ORDER BY 1;
