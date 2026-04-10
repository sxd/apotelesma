\set QUIET 1

DROP FOREIGN DATA WRAPPER IF EXISTS ekorre CASCADE;
DROP FUNCTION IF EXISTS ekorre_handler() CASCADE;
DROP FUNCTION IF EXISTS ekorre_validator(text[], oid) CASCADE;

CREATE FUNCTION ekorre_handler() RETURNS fdw_handler
AS :'module_path', 'ekorre_handler'
LANGUAGE C
STRICT;

CREATE FUNCTION ekorre_validator(text[], oid) RETURNS void
AS :'module_path', 'ekorre_validator'
LANGUAGE C
STRICT;

CREATE FOREIGN DATA WRAPPER ekorre
HANDLER ekorre_handler
VALIDATOR ekorre_validator;
