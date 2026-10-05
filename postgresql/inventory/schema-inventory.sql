/*
Purpose:
Capture a read-only PostgreSQL schema inventory for drift analysis.
Target: PostgreSQL 11 or later.

Concepts demonstrated:
- PostgreSQL system catalogs
- Relation sizing and object metadata
- Constraints, indexes, sequences, and routine signatures

Notes:
This script does not create persistent objects. Its result sets contain
schema metadata from the connected database; handle exported results as
potentially sensitive. Routine and view bodies are intentionally omitted.
*/

-- 1. Tables and partitioned tables
SELECT
    namespace.nspname AS schema_name,
    relation.relname AS table_name,
    CASE relation.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned table'
    END AS relation_type,
    pg_total_relation_size(relation.oid) AS total_bytes,
    pg_relation_size(relation.oid) AS table_bytes,
    pg_indexes_size(relation.oid) AS indexes_bytes
FROM pg_class AS relation
INNER JOIN pg_namespace AS namespace
    ON namespace.oid = relation.relnamespace
WHERE relation.relkind IN ('r', 'p')
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND namespace.nspname NOT LIKE 'pg_temp_%'
  AND namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    namespace.nspname,
    relation.relname;

-- 2. Columns, types, nullability, and identity configuration
SELECT
    namespace.nspname AS schema_name,
    relation.relname AS table_name,
    attribute.attnum AS column_ordinal,
    attribute.attname AS column_name,
    format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
    NOT attribute.attnotnull AS is_nullable,
    attribute.attidentity AS identity_kind
FROM pg_attribute AS attribute
INNER JOIN pg_class AS relation
    ON relation.oid = attribute.attrelid
INNER JOIN pg_namespace AS namespace
    ON namespace.oid = relation.relnamespace
WHERE attribute.attnum > 0
  AND NOT attribute.attisdropped
  AND relation.relkind IN ('r', 'p')
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND namespace.nspname NOT LIKE 'pg_temp_%'
  AND namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    namespace.nspname,
    relation.relname,
    attribute.attnum;

-- 3. Primary, unique, foreign-key, and check constraints
SELECT
    child_namespace.nspname AS schema_name,
    child_relation.relname AS table_name,
    constraint_catalog.conname AS constraint_name,
    constraint_catalog.contype AS constraint_type,
    constraint_catalog.convalidated AS is_validated,
    pg_get_constraintdef(constraint_catalog.oid, true) AS constraint_definition,
    parent_namespace.nspname AS referenced_schema_name,
    parent_relation.relname AS referenced_table_name
FROM pg_constraint AS constraint_catalog
INNER JOIN pg_class AS child_relation
    ON child_relation.oid = constraint_catalog.conrelid
INNER JOIN pg_namespace AS child_namespace
    ON child_namespace.oid = child_relation.relnamespace
LEFT OUTER JOIN pg_class AS parent_relation
    ON parent_relation.oid = constraint_catalog.confrelid
LEFT OUTER JOIN pg_namespace AS parent_namespace
    ON parent_namespace.oid = parent_relation.relnamespace
WHERE constraint_catalog.contype IN ('p', 'u', 'f', 'c')
  AND child_namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND child_namespace.nspname NOT LIKE 'pg_temp_%'
  AND child_namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    child_namespace.nspname,
    child_relation.relname,
    constraint_catalog.conname;

-- 4. Index definitions and validity
SELECT
    namespace.nspname AS schema_name,
    table_relation.relname AS table_name,
    index_relation.relname AS index_name,
    index_catalog.indisprimary AS is_primary,
    index_catalog.indisunique AS is_unique,
    index_catalog.indisvalid AS is_valid,
    pg_get_indexdef(index_catalog.indexrelid, 0, true) AS index_definition
FROM pg_index AS index_catalog
INNER JOIN pg_class AS table_relation
    ON table_relation.oid = index_catalog.indrelid
INNER JOIN pg_class AS index_relation
    ON index_relation.oid = index_catalog.indexrelid
INNER JOIN pg_namespace AS namespace
    ON namespace.oid = table_relation.relnamespace
WHERE table_relation.relkind IN ('r', 'p')
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND namespace.nspname NOT LIKE 'pg_temp_%'
  AND namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    namespace.nspname,
    table_relation.relname,
    index_relation.relname;

-- 5. Sequences and their owned-by relationships
SELECT
    namespace.nspname AS schema_name,
    sequence_relation.relname AS sequence_name,
    sequence_metadata.seqstart AS start_value,
    sequence_metadata.seqmin AS minimum_value,
    sequence_metadata.seqmax AS maximum_value,
    sequence_metadata.seqincrement AS increment_by,
    sequence_metadata.seqcycle AS cycles,
    sequence_metadata.seqcache AS cache_size,
    owned_relation.relname AS owned_by_table,
    owned_attribute.attname AS owned_by_column
FROM pg_class AS sequence_relation
INNER JOIN pg_namespace AS namespace
    ON namespace.oid = sequence_relation.relnamespace
LEFT OUTER JOIN pg_sequence AS sequence_metadata
    ON sequence_metadata.seqrelid = sequence_relation.oid
LEFT OUTER JOIN pg_depend AS dependency
    ON dependency.classid = 'pg_class'::regclass
   AND dependency.objid = sequence_relation.oid
   AND dependency.refclassid = 'pg_class'::regclass
   AND dependency.deptype IN ('a', 'i')
LEFT OUTER JOIN pg_class AS owned_relation
    ON owned_relation.oid = dependency.refobjid
LEFT OUTER JOIN pg_attribute AS owned_attribute
    ON owned_attribute.attrelid = dependency.refobjid
   AND owned_attribute.attnum = dependency.refobjsubid
WHERE sequence_relation.relkind = 'S'
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND namespace.nspname NOT LIKE 'pg_temp_%'
  AND namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    namespace.nspname,
    sequence_relation.relname;

-- 6. Routine signatures only; routine definitions are intentionally excluded
SELECT
    namespace.nspname AS schema_name,
    routine.proname AS routine_name,
    CASE routine.prokind
        WHEN 'f' THEN 'function'
        WHEN 'p' THEN 'procedure'
        WHEN 'a' THEN 'aggregate'
        WHEN 'w' THEN 'window function'
        ELSE 'other'
    END AS routine_type,
    pg_get_function_identity_arguments(routine.oid) AS identity_arguments,
    pg_get_function_result(routine.oid) AS result_type
FROM pg_proc AS routine
INNER JOIN pg_namespace AS namespace
    ON namespace.oid = routine.pronamespace
WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND namespace.nspname NOT LIKE 'pg_temp_%'
  AND namespace.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY
    namespace.nspname,
    routine.proname,
    pg_get_function_identity_arguments(routine.oid);
