-- =============================================================================
--  scripts/run-all.sql
--  Builds the full database from the numbered scripts in sql/, in order.
--
--  MUST be run from the repository root, because SOURCE resolves paths
--  against the client's working directory at connect time, not against the
--  location of this file:
--
--      mysql -u root -p < scripts/run-all.sql
--
--  WARNING -- DESTRUCTIVE. 01_schema.sql opens with DROP TABLE IF EXISTS on
--  all 8 tables before recreating them. Running this file against a database
--  that already holds data (seeded or otherwise) deletes that data with no
--  prompt and no backup. It is safe to run only against a fresh or throwaway
--  database. To rebuild a populated environment afterwards:
--
--      mysql < sql/03_reference_data.sql
--      mysql < sql/07_seed.sql
--
--  07_seed.sql is left commented out below. It builds 100,000 orders and
--  takes roughly 90 seconds. Uncomment it for a populated database; leave it
--  out for a fast structural build (schema, triggers, procedures, views,
--  events, grants) with no demo data.
-- =============================================================================

SOURCE sql/01_schema.sql;
SOURCE sql/02_triggers.sql;
SOURCE sql/03_reference_data.sql;
SOURCE sql/04_procedures.sql;
SOURCE sql/05_views.sql;
SOURCE sql/06_events.sql;

-- SOURCE sql/07_seed.sql;

SOURCE sql/08_reports.sql;
SOURCE sql/09_reconciliation.sql;
SOURCE sql/10_grants.sql;
