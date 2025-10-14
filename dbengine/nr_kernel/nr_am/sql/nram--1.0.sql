-- nram--1.0.sql
CREATE FUNCTION nram_tableam_handler(internal)
RETURNS table_am_handler
AS 'nram', 'nram_tableam_handler'
LANGUAGE C STRICT;

CREATE ACCESS METHOD nram TYPE TABLE HANDLER nram_tableam_handler;

CREATE OR REPLACE FUNCTION nram_load_policy(path text)
RETURNS void
AS 'nram', 'nram_load_policy'
LANGUAGE C
STRICT
VOLATILE
PARALLEL RESTRICTED;

CREATE OR REPLACE FUNCTION run_nram_tests()
RETURNS void
AS 'nram', 'run_nram_tests'
LANGUAGE C STRICT;


-- nrindex index access method
CREATE FUNCTION nrindex_handler(internal)
RETURNS index_am_handler
AS 'nram', 'nrindex_handler'
LANGUAGE C STRICT;

CREATE ACCESS METHOD nrindex TYPE INDEX HANDLER nrindex_handler;