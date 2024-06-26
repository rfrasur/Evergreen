--Upgrade Script for 3.7.2 to 3.7.3
\set eg_version '''3.7.3'''
BEGIN;
INSERT INTO config.upgrade_log (version, applied_to) VALUES ('3.7.3', :eg_version);

SELECT evergreen.upgrade_deps_block_check('1306', :eg_version);

-- We don't pass this function arrays with nulls, so we save 5% not testing for that
CREATE OR REPLACE FUNCTION evergreen.text_array_merge_unique (
    TEXT[], TEXT[]
) RETURNS TEXT[] AS $F$
    SELECT NULLIF(ARRAY(
        SELECT * FROM UNNEST($1) x
            UNION
        SELECT * FROM UNNEST($2) y
    ),'{}');
$F$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION search.symspell_build_raw_entry (
    raw_input       TEXT,
    source_class    TEXT,
    no_limit        BOOL DEFAULT FALSE,
    prefix_length   INT DEFAULT 6,
    maxED           INT DEFAULT 3
) RETURNS SETOF search.symspell_dictionary AS $F$
DECLARE
    key         TEXT;
    del_key     TEXT;
    key_list    TEXT[];
    entry       search.symspell_dictionary%ROWTYPE;
BEGIN
    key := raw_input;

    IF NOT no_limit AND CHARACTER_LENGTH(raw_input) > prefix_length THEN
        key := SUBSTRING(key FROM 1 FOR prefix_length);
        key_list := ARRAY[raw_input, key];
    ELSE
        key_list := ARRAY[key];
    END IF;

    FOREACH del_key IN ARRAY key_list LOOP
        -- skip empty keys
        CONTINUE WHEN del_key IS NULL OR CHARACTER_LENGTH(del_key) = 0;

        entry.prefix_key := del_key;

        entry.keyword_count := 0;
        entry.title_count := 0;
        entry.author_count := 0;
        entry.subject_count := 0;
        entry.series_count := 0;
        entry.identifier_count := 0;

        entry.keyword_suggestions := '{}';
        entry.title_suggestions := '{}';
        entry.author_suggestions := '{}';
        entry.subject_suggestions := '{}';
        entry.series_suggestions := '{}';
        entry.identifier_suggestions := '{}';

        IF source_class = 'keyword' THEN entry.keyword_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'title' THEN entry.title_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'author' THEN entry.author_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'subject' THEN entry.subject_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'series' THEN entry.series_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'identifier' THEN entry.identifier_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'keyword' THEN entry.keyword_suggestions := ARRAY[raw_input]; END IF;

        IF del_key = raw_input THEN
            IF source_class = 'keyword' THEN entry.keyword_count := 1; END IF;
            IF source_class = 'title' THEN entry.title_count := 1; END IF;
            IF source_class = 'author' THEN entry.author_count := 1; END IF;
            IF source_class = 'subject' THEN entry.subject_count := 1; END IF;
            IF source_class = 'series' THEN entry.series_count := 1; END IF;
            IF source_class = 'identifier' THEN entry.identifier_count := 1; END IF;
        END IF;

        RETURN NEXT entry;
    END LOOP;

    FOR del_key IN SELECT x FROM UNNEST(search.symspell_generate_edits(key, 1, maxED)) x LOOP

        -- skip empty keys
        CONTINUE WHEN del_key IS NULL OR CHARACTER_LENGTH(del_key) = 0;
        -- skip suggestions that are already too long for the prefix key
        CONTINUE WHEN CHARACTER_LENGTH(del_key) <= (prefix_length - maxED) AND CHARACTER_LENGTH(raw_input) > prefix_length;

        entry.keyword_suggestions := '{}';
        entry.title_suggestions := '{}';
        entry.author_suggestions := '{}';
        entry.subject_suggestions := '{}';
        entry.series_suggestions := '{}';
        entry.identifier_suggestions := '{}';

        IF source_class = 'keyword' THEN entry.keyword_count := 0; END IF;
        IF source_class = 'title' THEN entry.title_count := 0; END IF;
        IF source_class = 'author' THEN entry.author_count := 0; END IF;
        IF source_class = 'subject' THEN entry.subject_count := 0; END IF;
        IF source_class = 'series' THEN entry.series_count := 0; END IF;
        IF source_class = 'identifier' THEN entry.identifier_count := 0; END IF;

        entry.prefix_key := del_key;

        IF source_class = 'keyword' THEN entry.keyword_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'title' THEN entry.title_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'author' THEN entry.author_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'subject' THEN entry.subject_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'series' THEN entry.series_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'identifier' THEN entry.identifier_suggestions := ARRAY[raw_input]; END IF;
        IF source_class = 'keyword' THEN entry.keyword_suggestions := ARRAY[raw_input]; END IF;

        RETURN NEXT entry;
    END LOOP;

END;
$F$ LANGUAGE PLPGSQL STRICT IMMUTABLE;

CREATE OR REPLACE FUNCTION search.symspell_build_entries (
    full_input      TEXT,
    source_class    TEXT,
    old_input       TEXT DEFAULT NULL,
    include_phrases BOOL DEFAULT FALSE
) RETURNS SETOF search.symspell_dictionary AS $F$
DECLARE
    prefix_length   INT;
    maxED           INT;
    word_list   TEXT[];
    input       TEXT;
    word        TEXT;
    entry       search.symspell_dictionary;
BEGIN
    IF full_input IS NOT NULL THEN
        SELECT value::INT INTO prefix_length FROM config.internal_flag WHERE name = 'symspell.prefix_length' AND enabled;
        prefix_length := COALESCE(prefix_length, 6);

        SELECT value::INT INTO maxED FROM config.internal_flag WHERE name = 'symspell.max_edit_distance' AND enabled;
        maxED := COALESCE(maxED, 3);

        input := evergreen.lowercase(full_input);
        word_list := ARRAY_AGG(x) FROM search.symspell_parse_words_distinct(input) x;
        IF word_list IS NULL THEN
            RETURN;
        END IF;
    
        IF CARDINALITY(word_list) > 1 AND include_phrases THEN
            RETURN QUERY SELECT * FROM search.symspell_build_raw_entry(input, source_class, TRUE, prefix_length, maxED);
        END IF;

        FOREACH word IN ARRAY word_list LOOP
            -- Skip words that have runs of 5 or more digits (I'm looking at you, ISxNs)
            CONTINUE WHEN CHARACTER_LENGTH(word) > 4 AND word ~ '\d{5,}';
            RETURN QUERY SELECT * FROM search.symspell_build_raw_entry(word, source_class, FALSE, prefix_length, maxED);
        END LOOP;
    END IF;

    IF old_input IS NOT NULL THEN
        input := evergreen.lowercase(old_input);

        FOR word IN SELECT x FROM search.symspell_parse_words_distinct(input) x LOOP
            -- similarly skip words that have 5 or more digits here to
            -- avoid adding erroneous prefix deletion entries to the dictionary
            CONTINUE WHEN CHARACTER_LENGTH(word) > 4 AND word ~ '\d{5,}';
            entry.prefix_key := word;

            entry.keyword_count := 0;
            entry.title_count := 0;
            entry.author_count := 0;
            entry.subject_count := 0;
            entry.series_count := 0;
            entry.identifier_count := 0;

            entry.keyword_suggestions := '{}';
            entry.title_suggestions := '{}';
            entry.author_suggestions := '{}';
            entry.subject_suggestions := '{}';
            entry.series_suggestions := '{}';
            entry.identifier_suggestions := '{}';

            IF source_class = 'keyword' THEN entry.keyword_count := -1; END IF;
            IF source_class = 'title' THEN entry.title_count := -1; END IF;
            IF source_class = 'author' THEN entry.author_count := -1; END IF;
            IF source_class = 'subject' THEN entry.subject_count := -1; END IF;
            IF source_class = 'series' THEN entry.series_count := -1; END IF;
            IF source_class = 'identifier' THEN entry.identifier_count := -1; END IF;

            RETURN NEXT entry;
        END LOOP;
    END IF;
END;
$F$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION search.symspell_build_and_merge_entries (
    full_input      TEXT,
    source_class    TEXT,
    old_input       TEXT DEFAULT NULL,
    include_phrases BOOL DEFAULT FALSE
) RETURNS SETOF search.symspell_dictionary AS $F$
DECLARE
    new_entry       RECORD;
    conflict_entry  RECORD;
BEGIN

    IF full_input = old_input THEN -- neither NULL, and are the same
        RETURN;
    END IF;

    FOR new_entry IN EXECUTE $q$
        SELECT  count,
                prefix_key,
                s AS suggestions
          FROM  (SELECT prefix_key,
                        ARRAY_AGG(DISTINCT $q$ || source_class || $q$_suggestions[1]) s,
                        SUM($q$ || source_class || $q$_count) count
                  FROM  search.symspell_build_entries($1, $2, $3, $4)
                  GROUP BY 1) x
        $q$ USING full_input, source_class, old_input, include_phrases
    LOOP
        EXECUTE $q$
            SELECT  prefix_key,
                    $q$ || source_class || $q$_suggestions suggestions,
                    $q$ || source_class || $q$_count count
              FROM  search.symspell_dictionary
              WHERE prefix_key = $1 $q$
            INTO conflict_entry
            USING new_entry.prefix_key;

        IF new_entry.count <> 0 THEN -- Real word, and count changed
            IF conflict_entry.prefix_key IS NOT NULL THEN -- we'll be updating
                IF conflict_entry.count > 0 THEN -- it's a real word
                    RETURN QUERY EXECUTE $q$
                        UPDATE  search.symspell_dictionary
                           SET  $q$ || source_class || $q$_count = $2
                          WHERE prefix_key = $1
                          RETURNING * $q$
                        USING new_entry.prefix_key, GREATEST(0, new_entry.count + conflict_entry.count);
                ELSE -- it was a prefix key or delete-emptied word before
                    IF conflict_entry.suggestions @> new_entry.suggestions THEN -- already have all suggestions here...
                        RETURN QUERY EXECUTE $q$
                            UPDATE  search.symspell_dictionary
                               SET  $q$ || source_class || $q$_count = $2
                              WHERE prefix_key = $1
                              RETURNING * $q$
                            USING new_entry.prefix_key, GREATEST(0, new_entry.count);
                    ELSE -- new suggestion!
                        RETURN QUERY EXECUTE $q$
                            UPDATE  search.symspell_dictionary
                               SET  $q$ || source_class || $q$_count = $2,
                                    $q$ || source_class || $q$_suggestions = $3
                              WHERE prefix_key = $1
                              RETURNING * $q$
                            USING new_entry.prefix_key, GREATEST(0, new_entry.count), evergreen.text_array_merge_unique(conflict_entry.suggestions,new_entry.suggestions);
                    END IF;
                END IF;
            ELSE
                -- We keep the on-conflict clause just in case...
                RETURN QUERY EXECUTE $q$
                    INSERT INTO search.symspell_dictionary AS d (
                        $q$ || source_class || $q$_count,
                        prefix_key,
                        $q$ || source_class || $q$_suggestions
                    ) VALUES ( $1, $2, $3 ) ON CONFLICT (prefix_key) DO
                        UPDATE SET  $q$ || source_class || $q$_count = d.$q$ || source_class || $q$_count + EXCLUDED.$q$ || source_class || $q$_count,
                                    $q$ || source_class || $q$_suggestions = evergreen.text_array_merge_unique(d.$q$ || source_class || $q$_suggestions, EXCLUDED.$q$ || source_class || $q$_suggestions)
                        RETURNING * $q$
                    USING new_entry.count, new_entry.prefix_key, new_entry.suggestions;
            END IF;
        ELSE -- key only, or no change
            IF conflict_entry.prefix_key IS NOT NULL THEN -- we'll be updating
                IF NOT conflict_entry.suggestions @> new_entry.suggestions THEN -- There are new suggestions
                    RETURN QUERY EXECUTE $q$
                        UPDATE  search.symspell_dictionary
                           SET  $q$ || source_class || $q$_suggestions = $2
                          WHERE prefix_key = $1
                          RETURNING * $q$
                        USING new_entry.prefix_key, evergreen.text_array_merge_unique(conflict_entry.suggestions,new_entry.suggestions);
                END IF;
            ELSE
                RETURN QUERY EXECUTE $q$
                    INSERT INTO search.symspell_dictionary AS d (
                        $q$ || source_class || $q$_count,
                        prefix_key,
                        $q$ || source_class || $q$_suggestions
                    ) VALUES ( $1, $2, $3 ) ON CONFLICT (prefix_key) DO -- key exists, suggestions may be added due to this entry
                        UPDATE SET  $q$ || source_class || $q$_suggestions = evergreen.text_array_merge_unique(d.$q$ || source_class || $q$_suggestions, EXCLUDED.$q$ || source_class || $q$_suggestions)
                    RETURNING * $q$
                    USING new_entry.count, new_entry.prefix_key, new_entry.suggestions;
            END IF;
        END IF;
    END LOOP;
END;
$F$ LANGUAGE PLPGSQL;


\qecho ''
\qecho 'The following should be run at the end of the upgrade before any'
\qecho 'reingest occurs.  Because new triggers are installed already,'
\qecho 'updates to indexed strings will cause zero-count dictionary entries'
\qecho 'to be recorded which will require updating every row again (or'
\qecho 'starting from scratch) so best to do this before other batch'
\qecho 'changes.  A later reingest that does not significantly change'
\qecho 'indexed strings will /not/ cause table bloat here, and will be'
\qecho 'as fast as normal.  A copy of the SQL in a ready-to-use, non-escaped'
\qecho 'form is available inside a comment at the end of this upgrade sub-'
\qecho 'script so you do not need to copy this comment from the psql ouptut.'
\qecho ''
\qecho '\\a'
\qecho '\\t'
\qecho ''
\qecho '\\o title'
\qecho 'select value from metabib.title_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho '\\o author'
\qecho 'select value from metabib.author_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho '\\o subject'
\qecho 'select value from metabib.subject_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho '\\o series'
\qecho 'select value from metabib.series_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho '\\o identifier'
\qecho 'select value from metabib.identifier_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho '\\o keyword'
\qecho 'select value from metabib.keyword_field_entry where source in (select id from biblio.record_entry where not deleted);'
\qecho ''
\qecho '\\o'
\qecho '\\a'
\qecho '\\t'
\qecho ''
\qecho '// Then, at the command line:'
\qecho ''
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl title > title.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl author > author.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl subject > subject.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl series > series.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl identifier > identifier.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl keyword > keyword.sql'
\qecho ''
\qecho '// And, back in psql'
\qecho ''
\qecho 'ALTER TABLE search.symspell_dictionary SET UNLOGGED;'
\qecho 'TRUNCATE search.symspell_dictionary;'
\qecho ''
\qecho '\\i identifier.sql'
\qecho '\\i author.sql'
\qecho '\\i title.sql'
\qecho '\\i subject.sql'
\qecho '\\i series.sql'
\qecho '\\i keyword.sql'
\qecho ''
\qecho 'CLUSTER search.symspell_dictionary USING symspell_dictionary_pkey;'
\qecho 'REINDEX TABLE search.symspell_dictionary;'
\qecho 'ALTER TABLE search.symspell_dictionary SET LOGGED;'
\qecho 'VACUUM ANALYZE search.symspell_dictionary;'
\qecho ''
\qecho 'DROP TABLE search.symspell_dictionary_partial_title;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_author;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_subject;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_series;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_identifier;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_keyword;'

/* To run by hand:

\a
\t

\o title
select value from metabib.title_field_entry where source in (select id from biblio.record_entry where not deleted);

\o author
select value from metabib.author_field_entry where source in (select id from biblio.record_entry where not deleted);

\o subject
select value from metabib.subject_field_entry where source in (select id from biblio.record_entry where not deleted);

\o series
select value from metabib.series_field_entry where source in (select id from biblio.record_entry where not deleted);

\o identifier
select value from metabib.identifier_field_entry where source in (select id from biblio.record_entry where not deleted);

\o keyword
select value from metabib.keyword_field_entry where source in (select id from biblio.record_entry where not deleted);

\o
\a
\t

// Then, at the command line:

$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl title > title.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl author > author.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl subject > subject.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl series > series.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl identifier > identifier.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl keyword > keyword.sql

// To the extent your hardware allows, the above commands can be run in 
// in parallel, in different shells.  Each will use a full CPU, and RAM
// may be a limiting resource, so keep an eye on that with `top`.


// And, back in psql

ALTER TABLE search.symspell_dictionary SET UNLOGGED;
TRUNCATE search.symspell_dictionary;

\i identifier.sql
\i author.sql
\i title.sql
\i subject.sql
\i series.sql
\i keyword.sql

CLUSTER search.symspell_dictionary USING symspell_dictionary_pkey;
REINDEX TABLE search.symspell_dictionary;
ALTER TABLE search.symspell_dictionary SET LOGGED;
VACUUM ANALYZE search.symspell_dictionary;

DROP TABLE search.symspell_dictionary_partial_title;
DROP TABLE search.symspell_dictionary_partial_author;
DROP TABLE search.symspell_dictionary_partial_subject;
DROP TABLE search.symspell_dictionary_partial_series;
DROP TABLE search.symspell_dictionary_partial_identifier;
DROP TABLE search.symspell_dictionary_partial_keyword;

*/


SELECT evergreen.upgrade_deps_block_check('1309', :eg_version);

ALTER TABLE asset.course_module_term
        DROP CONSTRAINT course_module_term_name_key;

ALTER TABLE asset.course_module_term
        ADD CONSTRAINT cmt_once_per_owning_lib UNIQUE (owning_lib, name);


SELECT evergreen.upgrade_deps_block_check('1311', :eg_version);

CREATE OR REPLACE FUNCTION biblio.extract_located_uris( bib_id BIGINT, marcxml TEXT, editor_id INT ) RETURNS VOID AS $func$
DECLARE
    uris            TEXT[];
    uri_xml         TEXT;
    uri_label       TEXT;
    uri_href        TEXT;
    uri_use         TEXT;
    uri_owner_list  TEXT[];
    uri_owner       TEXT;
    uri_owner_id    INT;
    uri_id          INT;
    uri_cn_id       INT;
    uri_map_id      INT;
    current_uri     INT;
    current_map     INT;
    uri_map_count   INT;
    current_uri_map_list    INT[];
    current_map_owner_list  INT[];

BEGIN

    uris := oils_xpath('//*[@tag="856" and (@ind1="4" or @ind1="1") and (@ind2="0" or @ind2="1")]',marcxml);
    IF ARRAY_UPPER(uris,1) > 0 THEN
        FOR i IN 1 .. ARRAY_UPPER(uris, 1) LOOP
            -- First we pull info out of the 856
            uri_xml     := uris[i];

            uri_href    := (oils_xpath('//*[@code="u"]/text()',uri_xml))[1];
            uri_label   := (oils_xpath('//*[@code="y"]/text()|//*[@code="3"]/text()',uri_xml))[1];
            uri_use     := (oils_xpath('//*[@code="z"]/text()|//*[@code="2"]/text()|//*[@code="n"]/text()',uri_xml))[1];

            IF uri_label IS NULL THEN
                uri_label := uri_href;
            END IF;
            CONTINUE WHEN uri_href IS NULL;

            -- Get the distinct list of libraries wanting to use 
            SELECT  ARRAY_AGG(
                        DISTINCT REGEXP_REPLACE(
                            x,
                            $re$^.*?\((\w+)\).*$$re$,
                            E'\\1'
                        )
                    ) INTO uri_owner_list
              FROM  UNNEST(
                        oils_xpath(
                            '//*[@code="9"]/text()|//*[@code="w"]/text()|//*[@code="n"]/text()',
                            uri_xml
                        )
                    )x;

            IF ARRAY_UPPER(uri_owner_list,1) > 0 THEN

                -- look for a matching uri
                IF uri_use IS NULL THEN
                    SELECT id INTO uri_id
                        FROM asset.uri
                        WHERE label = uri_label AND href = uri_href AND use_restriction IS NULL AND active
                        ORDER BY id LIMIT 1;
                    IF NOT FOUND THEN -- create one
                        INSERT INTO asset.uri (label, href, use_restriction) VALUES (uri_label, uri_href, uri_use);
                        SELECT id INTO uri_id
                            FROM asset.uri
                            WHERE label = uri_label AND href = uri_href AND use_restriction IS NULL AND active;
                    END IF;
                ELSE
                    SELECT id INTO uri_id
                        FROM asset.uri
                        WHERE label = uri_label AND href = uri_href AND use_restriction = uri_use AND active
                        ORDER BY id LIMIT 1;
                    IF NOT FOUND THEN -- create one
                        INSERT INTO asset.uri (label, href, use_restriction) VALUES (uri_label, uri_href, uri_use);
                        SELECT id INTO uri_id
                            FROM asset.uri
                            WHERE label = uri_label AND href = uri_href AND use_restriction = uri_use AND active;
                    END IF;
                END IF;

                FOR j IN 1 .. ARRAY_UPPER(uri_owner_list, 1) LOOP
                    uri_owner := uri_owner_list[j];

                    SELECT id INTO uri_owner_id FROM actor.org_unit WHERE shortname = BTRIM(REPLACE(uri_owner,chr(160),''));
                    CONTINUE WHEN NOT FOUND;

                    -- we need a call number to link through
                    SELECT id INTO uri_cn_id FROM asset.call_number WHERE owning_lib = uri_owner_id AND record = bib_id AND label = '##URI##' AND NOT deleted;
                    IF NOT FOUND THEN
                        INSERT INTO asset.call_number (owning_lib, record, create_date, edit_date, creator, editor, label)
                            VALUES (uri_owner_id, bib_id, 'now', 'now', editor_id, editor_id, '##URI##');
                        SELECT id INTO uri_cn_id FROM asset.call_number WHERE owning_lib = uri_owner_id AND record = bib_id AND label = '##URI##' AND NOT deleted;
                    END IF;

                    -- now, link them if they're not already
                    SELECT id INTO uri_map_id FROM asset.uri_call_number_map WHERE call_number = uri_cn_id AND uri = uri_id;
                    IF NOT FOUND THEN
                        INSERT INTO asset.uri_call_number_map (call_number, uri) VALUES (uri_cn_id, uri_id);
                        SELECT id INTO uri_map_id FROM asset.uri_call_number_map WHERE call_number = uri_cn_id AND uri = uri_id;
                    END IF;

                    current_uri_map_list := current_uri_map_list || uri_map_id;
                    current_map_owner_list := current_map_owner_list || uri_cn_id;

                END LOOP;

            END IF;

        END LOOP;
    END IF;

    -- Clear any orphaned URIs, URI mappings and call
    -- numbers for this bib that weren't mapped above.
    FOR current_map IN
        SELECT  m.id
          FROM  asset.uri_call_number_map m
                LEFT JOIN asset.call_number cn ON (cn.id = m.call_number)
          WHERE cn.record = bib_id
                AND cn.label = '##URI##'
                AND (NOT (m.id = ANY (current_uri_map_list))
                     OR current_uri_map_list is NULL)
    LOOP
        SELECT uri INTO current_uri FROM asset.uri_call_number_map WHERE id = current_map;
        DELETE FROM asset.uri_call_number_map WHERE id = current_map;

        SELECT COUNT(*) INTO uri_map_count FROM asset.uri_call_number_map WHERE uri = current_uri;
        IF uri_map_count = 0 THEN
            DELETE FROM asset.uri WHERE id = current_uri;
        END IF;
    END LOOP;

    UPDATE asset.call_number
    SET deleted = TRUE, edit_date = now(), editor = editor_id
    WHERE id IN (
        SELECT  id
          FROM  asset.call_number
          WHERE record = bib_id
                AND label = '##URI##'
                AND NOT deleted
                AND (NOT (id = ANY (current_map_owner_list))
                     OR current_map_owner_list is NULL)
    );

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;

-- Remove existing orphaned URIs from the database.
DELETE FROM asset.uri
WHERE id IN
(
SELECT uri.id
FROM asset.uri
LEFT JOIN asset.uri_call_number_map
ON uri_call_number_map.uri = uri.id
LEFT JOIN serial.item
ON item.uri = uri.id
WHERE uri_call_number_map IS NULL
AND item IS NULL
);



SELECT evergreen.upgrade_deps_block_check('1325', :eg_version);

UPDATE config.xml_transform SET xslt=$XSLT$<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:mads="http://www.loc.gov/mads/v2"
	xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:marc="http://www.loc.gov/MARC21/slim"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform" exclude-result-prefixes="marc">
	<xsl:output method="xml" indent="yes" encoding="UTF-8"/>
	<xsl:strip-space elements="*"/>

	<xsl:variable name="ascii">
		<xsl:text> !"#$%&amp;'()*+,-./0123456789:;&lt;=&gt;?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~</xsl:text>
	</xsl:variable>

	<xsl:variable name="latin1">
		<xsl:text> ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ</xsl:text>
	</xsl:variable>
	<!-- Characters that usually don't need to be escaped -->
	<xsl:variable name="safe">
		<xsl:text>!'()*-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~</xsl:text>
	</xsl:variable>

	<xsl:variable name="hex">0123456789ABCDEF</xsl:variable>


	<xsl:template name="datafield">
		<xsl:param name="tag"/>
		<xsl:param name="ind1">
			<xsl:text> </xsl:text>
		</xsl:param>
		<xsl:param name="ind2">
			<xsl:text> </xsl:text>
		</xsl:param>
		<xsl:param name="subfields"/>
		<xsl:element name="marc:datafield">
			<xsl:attribute name="tag">
				<xsl:value-of select="$tag"/>
			</xsl:attribute>
			<xsl:attribute name="ind1">
				<xsl:value-of select="$ind1"/>
			</xsl:attribute>
			<xsl:attribute name="ind2">
				<xsl:value-of select="$ind2"/>
			</xsl:attribute>
			<xsl:copy-of select="$subfields"/>
		</xsl:element>
	</xsl:template>

	<xsl:template name="subfieldSelect">
		<xsl:param name="codes">abcdefghijklmnopqrstuvwxyz</xsl:param>
		<xsl:param name="delimeter">
			<xsl:text> </xsl:text>
		</xsl:param>
		<xsl:variable name="str">
			<xsl:for-each select="marc:subfield">
				<xsl:if test="contains($codes, @code)">
					<xsl:value-of select="text()"/>
					<xsl:value-of select="$delimeter"/>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:value-of select="substring($str,1,string-length($str)-string-length($delimeter))"/>
	</xsl:template>

	<xsl:template name="buildSpaces">
		<xsl:param name="spaces"/>
		<xsl:param name="char">
			<xsl:text> </xsl:text>
		</xsl:param>
		<xsl:if test="$spaces>0">
			<xsl:value-of select="$char"/>
			<xsl:call-template name="buildSpaces">
				<xsl:with-param name="spaces" select="$spaces - 1"/>
				<xsl:with-param name="char" select="$char"/>
			</xsl:call-template>
		</xsl:if>
	</xsl:template>

	<xsl:template name="chopPunctuation">
		<xsl:param name="chopString"/>
		<xsl:param name="punctuation">
			<xsl:text>.:,;/ </xsl:text>
		</xsl:param>
		<xsl:variable name="length" select="string-length($chopString)"/>
		<xsl:choose>
			<xsl:when test="$length=0"/>
			<xsl:when test="contains($punctuation, substring($chopString,$length,1))">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="substring($chopString,1,$length - 1)"/>
					<xsl:with-param name="punctuation" select="$punctuation"/>
				</xsl:call-template>
			</xsl:when>
			<xsl:when test="not($chopString)"/>
			<xsl:otherwise>
				<xsl:value-of select="$chopString"/>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="chopPunctuationFront">
		<xsl:param name="chopString"/>
		<xsl:variable name="length" select="string-length($chopString)"/>
		<xsl:choose>
			<xsl:when test="$length=0"/>
			<xsl:when test="contains('.:,;/[ ', substring($chopString,1,1))">
				<xsl:call-template name="chopPunctuationFront">
					<xsl:with-param name="chopString" select="substring($chopString,2,$length - 1)"
					/>
				</xsl:call-template>
			</xsl:when>
			<xsl:when test="not($chopString)"/>
			<xsl:otherwise>
				<xsl:value-of select="$chopString"/>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="chopPunctuationBack">
		<xsl:param name="chopString"/>
		<xsl:param name="punctuation">
			<xsl:text>.:,;/] </xsl:text>
		</xsl:param>
		<xsl:variable name="length" select="string-length($chopString)"/>
		<xsl:choose>
			<xsl:when test="$length=0"/>
			<xsl:when test="contains($punctuation, substring($chopString,$length,1))">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="substring($chopString,1,$length - 1)"/>
					<xsl:with-param name="punctuation" select="$punctuation"/>
				</xsl:call-template>
			</xsl:when>
			<xsl:when test="not($chopString)"/>
			<xsl:otherwise>
				<xsl:value-of select="$chopString"/>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<!-- nate added 12/14/2007 for lccn.loc.gov: url encode ampersand, etc. -->
	<xsl:template name="url-encode">

		<xsl:param name="str"/>

		<xsl:if test="$str">
			<xsl:variable name="first-char" select="substring($str,1,1)"/>
			<xsl:choose>
				<xsl:when test="contains($safe,$first-char)">
					<xsl:value-of select="$first-char"/>
				</xsl:when>
				<xsl:otherwise>
					<xsl:variable name="codepoint">
						<xsl:choose>
							<xsl:when test="contains($ascii,$first-char)">
								<xsl:value-of
									select="string-length(substring-before($ascii,$first-char)) + 32"
								/>
							</xsl:when>
							<xsl:when test="contains($latin1,$first-char)">
								<xsl:value-of
									select="string-length(substring-before($latin1,$first-char)) + 160"/>
								<!-- was 160 -->
							</xsl:when>
							<xsl:otherwise>
								<xsl:message terminate="no">Warning: string contains a character
									that is out of range! Substituting "?".</xsl:message>
								<xsl:text>63</xsl:text>
							</xsl:otherwise>
						</xsl:choose>
					</xsl:variable>
					<xsl:variable name="hex-digit1"
						select="substring($hex,floor($codepoint div 16) + 1,1)"/>
					<xsl:variable name="hex-digit2" select="substring($hex,$codepoint mod 16 + 1,1)"/>
					<!-- <xsl:value-of select="concat('%',$hex-digit2)"/> -->
					<xsl:value-of select="concat('%',$hex-digit1,$hex-digit2)"/>
				</xsl:otherwise>
			</xsl:choose>
			<xsl:if test="string-length($str) &gt; 1">
				<xsl:call-template name="url-encode">
					<xsl:with-param name="str" select="substring($str,2)"/>
				</xsl:call-template>
			</xsl:if>
		</xsl:if>
	</xsl:template>


<!--
2.15  reversed genre and setAuthority template order under relatedTypeAttribute                       tmee 11/13/2018
2.14    Fixed bug in mads:geographic attributes syntax                                      ws   05/04/2016		
2.13	fixed repeating <geographic>														tmee 01/31/2014
2.12	added $2 authority for <classification>												tmee 09/18/2012
2.11	added delimiters between <classification> subfields									tmee 09/18/2012
2.10	fixed type="other" and type="otherType" for mads:related							tmee 09/16/2011
2.09	fixed professionTerm and genreTerm empty tag error									tmee 09/16/2011
2.08	fixed marc:subfield @code='i' matching error										tmee 09/16/2011
2.07	fixed 555 duplication error															tmee 08/10/2011	
2.06	fixed topic subfield error															tmee 08/10/2011	
2.05	fixed title subfield error															tmee 06/20/2011	
2.04	fixed geographicSubdivision mapping for authority element							tmee 06/16/2011
2.03	added classification for 053, 055, 060, 065, 070, 080, 082, 083, 086, 087			tmee 06/03/2011		
2.02	added descriptionStandard for 008/10												tmee 04/27/2011
2.01	added extensions for 046, 336, 370, 374, 375, 376									tmee 04/08/2011
2.00	redefined imported MODS elements in version 1.0 to MADS elements in version 2.0		tmee 02/08/2011
1.08	added 372 subfields $a $s $t for <fieldOfActivity>									tmee 06/24/2010
1.07	removed role/roleTerm 100, 110, 111, 400, 410, 411, 500, 510, 511, 700, 710, 711	tmee 06/24/2010
1.06	added strip-space																	tmee 06/24/2010
1.05	added subfield $a for 130, 430, 530													tmee 06/21/2010
1.04	fixed 550 z omission																ntra 08/11/2008
1.03	removed duplication of 550 $a text													tmee 11/01/2006
1.02	fixed namespace references between mads and mods									ntra 10/06/2006
1.01	revised																				rgue/jrad 11/29/05
1.00	adapted from MARC21Slim2MODS3.xsl													ntra 07/06/05
-->

	<!-- authority attribute defaults to 'naf' if not set using this authority parameter, for <authority> descriptors: name, titleInfo, geographic -->
	<xsl:param name="authority"/>
	<xsl:variable name="auth">
		<xsl:choose>
			<xsl:when test="$authority">
				<xsl:value-of select="$authority"/>
			</xsl:when>
			<xsl:otherwise>naf</xsl:otherwise>
		</xsl:choose>
	</xsl:variable>
	<xsl:variable name="controlField008" select="marc:controlfield[@tag='008']"/>
	<xsl:variable name="controlField008-06"
		select="substring(descendant-or-self::marc:controlfield[@tag=008],7,1)"/>
	<xsl:variable name="controlField008-11"
		select="substring(descendant-or-self::marc:controlfield[@tag=008],12,1)"/>
	<xsl:variable name="controlField008-14"
		select="substring(descendant-or-self::marc:controlfield[@tag=008],15,1)"/>
	<xsl:template match="/">
		<xsl:choose>
			<xsl:when test="descendant-or-self::marc:collection">
				<mads:madsCollection xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
					xsi:schemaLocation="http://www.loc.gov/mads/v2 http://www.loc.gov/standards/mads/v2/mads-2-0.xsd">
					<xsl:for-each select="descendant-or-self::marc:collection/marc:record">
						<mads:mads version="2.0">
							<xsl:call-template name="marcRecord"/>
						</mads:mads>
					</xsl:for-each>
				</mads:madsCollection>
			</xsl:when>
			<xsl:otherwise>
				<mads:mads version="2.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
					xsi:schemaLocation="http://www.loc.gov/mads/v2 http://www.loc.gov/standards/mads/mads-2-0.xsd">
					<xsl:for-each select="descendant-or-self::marc:record">
						<xsl:call-template name="marcRecord"/>
					</xsl:for-each>
				</mads:mads>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="marcRecord">
		<mads:authority>
			<!-- 2.04 -->
			<xsl:choose>
				<xsl:when test="$controlField008-06='d'">
					<xsl:attribute name="geographicSubdivision">
						<xsl:text>direct</xsl:text>
					</xsl:attribute>
				</xsl:when>
				<xsl:when test="$controlField008-06='i'">
					<xsl:attribute name="geographicSubdivision">
						<xsl:text>indirect</xsl:text>
					</xsl:attribute>
				</xsl:when>
				<xsl:when test="$controlField008-06='n'">
					<xsl:attribute name="geographicSubdivision">
						<xsl:text>not applicable</xsl:text>
					</xsl:attribute>
				</xsl:when>
			</xsl:choose>
			
			<xsl:apply-templates select="marc:datafield[100 &lt;= @tag  and @tag &lt; 200]"/>		
		</mads:authority>

		<!-- related -->
		<xsl:apply-templates
			select="marc:datafield[500 &lt;= @tag and @tag &lt;= 585]|marc:datafield[700 &lt;= @tag and @tag &lt;= 785]"/>

		<!-- variant -->
		<xsl:apply-templates select="marc:datafield[400 &lt;= @tag and @tag &lt;= 485]"/>

		<!-- notes -->
		<xsl:apply-templates select="marc:datafield[667 &lt;= @tag and @tag &lt;= 688]"/>

		<!-- url -->
		<xsl:apply-templates select="marc:datafield[@tag=856]"/>
		<xsl:apply-templates select="marc:datafield[@tag=010]"/>
		<xsl:apply-templates select="marc:datafield[@tag=024]"/>
		<xsl:apply-templates select="marc:datafield[@tag=372]"/>
		
		<!-- classification -->
		<xsl:apply-templates select="marc:datafield[@tag=053]"/>
		<xsl:apply-templates select="marc:datafield[@tag=055]"/>
		<xsl:apply-templates select="marc:datafield[@tag=060]"/>
		<xsl:apply-templates select="marc:datafield[@tag=065]"/>
		<xsl:apply-templates select="marc:datafield[@tag=070]"/>
		<xsl:apply-templates select="marc:datafield[@tag=080]"/>
		<xsl:apply-templates select="marc:datafield[@tag=082]"/>
		<xsl:apply-templates select="marc:datafield[@tag=083]"/>
		<xsl:apply-templates select="marc:datafield[@tag=086]"/>
		<xsl:apply-templates select="marc:datafield[@tag=087]"/>

		<!-- affiliation-->
		<xsl:for-each select="marc:datafield[@tag=373]">
			<mads:affiliation>
				<mads:position>
					<xsl:value-of select="marc:subfield[@code='a']"/>
				</mads:position>
				<mads:dateValid point="start">
					<xsl:value-of select="marc:subfield[@code='s']"/>
				</mads:dateValid>
				<mads:dateValid point="end">
					<xsl:value-of select="marc:subfield[@code='t']"/>
				</mads:dateValid>
			</mads:affiliation>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=371]">
			<mads:affiliation>
				<mads:address>
					<mads:street>
						<xsl:value-of select="marc:subfield[@code='a']"/>
					</mads:street>
					<mads:city>
						<xsl:value-of select="marc:subfield[@code='b']"/>
					</mads:city>
					<mads:state>
						<xsl:value-of select="marc:subfield[@code='c']"/>
					</mads:state>
					<mads:country>
						<xsl:value-of select="marc:subfield[@code='d']"/>
					</mads:country>
					<mads:postcode>
						<xsl:value-of select="marc:subfield[@code='e']"/>
					</mads:postcode>
				</mads:address>
				<mads:email>
					<xsl:value-of select="marc:subfield[@code='m']"/>
				</mads:email>
			</mads:affiliation>
		</xsl:for-each>

		<!-- extension-->
		<xsl:for-each select="marc:datafield[@tag=336]">
			<mads:extension>
				<mads:contentType>
					<mads:contentType type="text">
						<xsl:value-of select="marc:subfield[@code='a']"/>
					</mads:contentType>
					<mads:contentType type="code">
						<xsl:value-of select="marc:subfield[@code='b']"/>
					</mads:contentType>
				</mads:contentType>
			</mads:extension>
		</xsl:for-each>

		<xsl:for-each select="marc:datafield[@tag=374]">
			<mads:extension>
				<mads:profession>
					<xsl:choose>
						<xsl:when test="marc:subfield[@code='a']">
							<mads:professionTerm>
								<xsl:value-of select="marc:subfield[@code='a']"/>
							</mads:professionTerm>
						</xsl:when>
						<xsl:when test="marc:subfield[@code='s']">
							<mads:dateValid point="start">
								<xsl:value-of select="marc:subfield[@code='s']"/>
							</mads:dateValid>
						</xsl:when>
						<xsl:when test="marc:subfield[@code='t']">
							<mads:dateValid point="end">
								<xsl:value-of select="marc:subfield[@code='t']"/>
							</mads:dateValid>
						</xsl:when>
					</xsl:choose>
				</mads:profession>
			</mads:extension>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=375]">
			<mads:extension>
				<mads:gender>
					<xsl:choose>
						<xsl:when test="marc:subfield[@code='a']">
							<mads:genderTerm>
								<xsl:value-of select="marc:subfield[@code='a']"/>
							</mads:genderTerm>
						</xsl:when>
						<xsl:when test="marc:subfield[@code='s']">
							<mads:dateValid point="start">
								<xsl:value-of select="marc:subfield[@code='s']"/>
							</mads:dateValid>
						</xsl:when>
						<xsl:when test="marc:subfield[@code='t']">
							<mads:dateValid point="end">
								<xsl:value-of select="marc:subfield[@code='t']"/>
							</mads:dateValid>
						</xsl:when>
					</xsl:choose>
				</mads:gender>
			</mads:extension>
		</xsl:for-each>

		<xsl:for-each select="marc:datafield[@tag=376]">
			<mads:extension>
				<mads:familyInformation>
					<mads:typeOfFamily>
						<xsl:value-of select="marc:subfield[@code='a']"/>
					</mads:typeOfFamily>
					<mads:nameOfProminentMember>
						<xsl:value-of select="marc:subfield[@code='b']"/>
					</mads:nameOfProminentMember>
					<mads:hereditaryTitle>
						<xsl:value-of select="marc:subfield[@code='c']"/>
					</mads:hereditaryTitle>
					<mads:dateValid point="start">
						<xsl:value-of select="marc:subfield[@code='s']"/>
					</mads:dateValid>
					<mads:dateValid point="end">
						<xsl:value-of select="marc:subfield[@code='t']"/>
					</mads:dateValid>
				</mads:familyInformation>
			</mads:extension>
		</xsl:for-each>

		<mads:recordInfo>
			<mads:recordOrigin>Converted from MARCXML to MADS version 2.0 (Revision 2.13)</mads:recordOrigin>
			<!-- <xsl:apply-templates select="marc:datafield[@tag=024]"/> -->

			<xsl:apply-templates select="marc:datafield[@tag=040]/marc:subfield[@code='a']"/>
			<xsl:apply-templates select="marc:controlfield[@tag=005]"/>
			<xsl:apply-templates select="marc:controlfield[@tag=001]"/>
			<xsl:apply-templates select="marc:datafield[@tag=040]/marc:subfield[@code='b']"/>
			<xsl:apply-templates select="marc:datafield[@tag=040]/marc:subfield[@code='e']"/>
			<xsl:for-each select="marc:controlfield[@tag=008]">
				<xsl:if test="substring(.,11,1)='a'">
					<mads:descriptionStandard>
						<xsl:text>earlier rules</xsl:text>
					</mads:descriptionStandard>
				</xsl:if>
				<xsl:if test="substring(.,11,1)='b'">
					<mads:descriptionStandard>
						<xsl:text>aacr1</xsl:text>
					</mads:descriptionStandard>
				</xsl:if>
				<xsl:if test="substring(.,11,1)='c'">
					<mads:descriptionStandard>
						<xsl:text>aacr2</xsl:text>
					</mads:descriptionStandard>
				</xsl:if>
				<xsl:if test="substring(.,11,1)='d'">
					<mads:descriptionStandard>
						<xsl:text>aacr2 compatible</xsl:text>
					</mads:descriptionStandard>
				</xsl:if>
				<xsl:if test="substring(.,11,1)='z'">
					<mads:descriptionStandard>
						<xsl:text>other rules</xsl:text>
					</mads:descriptionStandard>
				</xsl:if>
			</xsl:for-each>
		</mads:recordInfo>
	</xsl:template>

	<!-- start of secondary templates -->

	<!-- ======== xlink ======== -->

	<!-- <xsl:template name="uri"> 
    <xsl:for-each select="marc:subfield[@code='0']">
      <xsl:attribute name="xlink:href">
	<xsl:value-of select="."/>
      </xsl:attribute>
    </xsl:for-each>
     </xsl:template> 
   -->
	<xsl:template match="marc:subfield[@code='i']">
		<xsl:attribute name="otherType">
			<xsl:value-of select="."/>
		</xsl:attribute>
	</xsl:template>

	<!-- No role/roleTerm mapped in MADS 06/24/2010
	<xsl:template name="role">
		<xsl:for-each select="marc:subfield[@code='e']">
			<mads:role>
				<mads:roleTerm type="text">
					<xsl:value-of select="."/>
				</mads:roleTerm>
			</mads:role>
		</xsl:for-each>
	</xsl:template>
-->

	<xsl:template name="part">
		<xsl:variable name="partNumber">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">n</xsl:with-param>
				<xsl:with-param name="anyCodes">n</xsl:with-param>
				<xsl:with-param name="afterCodes">fghkdlmor</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:variable name="partName">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">p</xsl:with-param>
				<xsl:with-param name="anyCodes">p</xsl:with-param>
				<xsl:with-param name="afterCodes">fghkdlmor</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:if test="string-length(normalize-space($partNumber))">
			<mads:partNumber>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="$partNumber"/>
				</xsl:call-template>
			</mads:partNumber>
		</xsl:if>
		<xsl:if test="string-length(normalize-space($partName))">
			<mads:partName>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="$partName"/>
				</xsl:call-template>
			</mads:partName>
		</xsl:if>
	</xsl:template>

	<xsl:template name="nameABCDN">
		<xsl:for-each select="marc:subfield[@code='a']">
			<mads:namePart>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="."/>
				</xsl:call-template>
			</mads:namePart>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='b']">
			<mads:namePart>
				<xsl:value-of select="."/>
			</mads:namePart>
		</xsl:for-each>
		<xsl:if
			test="marc:subfield[@code='c'] or marc:subfield[@code='d'] or marc:subfield[@code='n']">
			<mads:namePart>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">cdn</xsl:with-param>
				</xsl:call-template>
			</mads:namePart>
		</xsl:if>
	</xsl:template>

	<xsl:template name="nameABCDQ">
		<mads:namePart>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">aq</xsl:with-param>
					</xsl:call-template>
				</xsl:with-param>
			</xsl:call-template>
		</mads:namePart>
		<xsl:call-template name="termsOfAddress"/>
		<xsl:call-template name="nameDate"/>
	</xsl:template>

	<xsl:template name="nameACDENQ">
		<mads:namePart>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">acdenq</xsl:with-param>
			</xsl:call-template>
		</mads:namePart>
	</xsl:template>

	<xsl:template name="nameDate">
		<xsl:for-each select="marc:subfield[@code='d']">
			<mads:namePart type="date">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="."/>
				</xsl:call-template>
			</mads:namePart>
		</xsl:for-each>
	</xsl:template>

	<xsl:template name="specialSubfieldSelect">
		<xsl:param name="anyCodes"/>
		<xsl:param name="axis"/>
		<xsl:param name="beforeCodes"/>
		<xsl:param name="afterCodes"/>
		<xsl:variable name="str">
			<xsl:for-each select="marc:subfield">
				<xsl:if
					test="contains($anyCodes, @code) or (contains($beforeCodes,@code) and following-sibling::marc:subfield[@code=$axis]) or (contains($afterCodes,@code) and preceding-sibling::marc:subfield[@code=$axis])">
					<xsl:value-of select="text()"/>
					<xsl:text> </xsl:text>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:value-of select="substring($str,1,string-length($str)-1)"/>
	</xsl:template>

	<xsl:template name="termsOfAddress">
		<xsl:if test="marc:subfield[@code='b' or @code='c']">
			<mads:namePart type="termsOfAddress">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">bc</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</mads:namePart>
		</xsl:if>
	</xsl:template>

	<xsl:template name="displayLabel">
		<xsl:if test="marc:subfield[@code='z']">
			<xsl:attribute name="displayLabel">
				<xsl:value-of select="marc:subfield[@code='z']"/>
			</xsl:attribute>
		</xsl:if>
		<xsl:if test="marc:subfield[@code='3']">
			<xsl:attribute name="displayLabel">
				<xsl:value-of select="marc:subfield[@code='3']"/>
			</xsl:attribute>
		</xsl:if>
	</xsl:template>

	<xsl:template name="isInvalid">
		<xsl:if test="@code='z'">
			<xsl:attribute name="invalid">yes</xsl:attribute>
		</xsl:if>
	</xsl:template>

	<xsl:template name="sub2Attribute">
		<!-- 024 -->
		<xsl:if test="../marc:subfield[@code='2']">
			<xsl:attribute name="type">
				<xsl:value-of select="../marc:subfield[@code='2']"/>
			</xsl:attribute>
		</xsl:if>
	</xsl:template>

	<xsl:template match="marc:controlfield[@tag=001]">
		<mads:recordIdentifier>
			<xsl:if test="../marc:controlfield[@tag=003]">
				<xsl:attribute name="source">
					<xsl:value-of select="../marc:controlfield[@tag=003]"/>
				</xsl:attribute>
			</xsl:if>
			<xsl:value-of select="."/>
		</mads:recordIdentifier>
	</xsl:template>

	<xsl:template match="marc:controlfield[@tag=005]">
		<mads:recordChangeDate encoding="iso8601">
			<xsl:value-of select="."/>
		</mads:recordChangeDate>
	</xsl:template>

	<xsl:template match="marc:controlfield[@tag=008]">
		<mads:recordCreationDate encoding="marc">
			<xsl:value-of select="substring(.,1,6)"/>
		</mads:recordCreationDate>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=010]">
		<xsl:for-each select="marc:subfield">
			<mads:identifier type="lccn">
				<xsl:call-template name="isInvalid"/>
				<xsl:value-of select="."/>
			</mads:identifier>
		</xsl:for-each>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=024]">
		<xsl:for-each select="marc:subfield[not(@code=2)]">
			<mads:identifier>
				<xsl:call-template name="isInvalid"/>
				<xsl:call-template name="sub2Attribute"/>
				<xsl:value-of select="."/>
			</mads:identifier>
		</xsl:for-each>
	</xsl:template>

	<!-- ========== 372 ========== -->
	<xsl:template match="marc:datafield[@tag=372]">
		<mads:fieldOfActivity>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">a</xsl:with-param>
			</xsl:call-template>
			<xsl:text>-</xsl:text>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">st</xsl:with-param>
			</xsl:call-template>
		</mads:fieldOfActivity>
	</xsl:template>


	<!-- ========== 040 ========== -->
	<xsl:template match="marc:datafield[@tag=040]/marc:subfield[@code='a']">
		<mads:recordContentSource authority="marcorg">
			<xsl:value-of select="."/>
		</mads:recordContentSource>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=040]/marc:subfield[@code='b']">
		<mads:languageOfCataloging>
			<mads:languageTerm authority="iso639-2b" type="code">
				<xsl:value-of select="."/>
			</mads:languageTerm>
		</mads:languageOfCataloging>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=040]/marc:subfield[@code='e']">
		<mads:descriptionStandard>
			<xsl:value-of select="."/>
		</mads:descriptionStandard>
	</xsl:template>
	
	<!-- ========== classification 2.03 ========== -->
	
	<xsl:template match="marc:datafield[@tag=053]">
		<mads:classification>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	
	<xsl:template match="marc:datafield[@tag=055]">
		<mads:classification>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	
	<xsl:template match="marc:datafield[@tag=060]">
		<mads:classification>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=065]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=070]">
		<mads:classification>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=080]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=082]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=083]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=086]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=087]">
		<mads:classification>
			<xsl:attribute name="authority">
				<xsl:value-of select="marc:subfield[@code='2']"/>
			</xsl:attribute>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">abcdxyz5</xsl:with-param>
				<xsl:with-param name="delimeter">-</xsl:with-param>
			</xsl:call-template>
		</mads:classification>
	</xsl:template>
	

	<!-- ========== names  ========== -->
	<xsl:template match="marc:datafield[@tag=100]">
		<mads:name type="personal">
			<xsl:call-template name="setAuthority"/>
			<xsl:call-template name="nameABCDQ"/>
		</mads:name>
		<xsl:apply-templates select="*[marc:subfield[not(contains('abcdeq',@code))]]"/>
		<xsl:call-template name="title"/>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=110]">
		<mads:name type="corporate">
			<xsl:call-template name="setAuthority"/>
			<xsl:call-template name="nameABCDN"/>
		</mads:name>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=111]">
		<mads:name type="conference">
			<xsl:call-template name="setAuthority"/>
			<xsl:call-template name="nameACDENQ"/>
		</mads:name>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=400]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<mads:name type="personal">
				<xsl:call-template name="nameABCDQ"/>
			</mads:name>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
			<xsl:call-template name="title"/>
		</mads:variant>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=410]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<mads:name type="corporate">
				<xsl:call-template name="nameABCDN"/>
			</mads:name>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:variant>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=411]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<mads:name type="conference">
				<xsl:call-template name="nameACDENQ"/>
			</mads:name>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:variant>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=500]|marc:datafield[@tag=700]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<mads:name type="personal">
				<xsl:call-template name="setAuthority"/>
				<xsl:call-template name="nameABCDQ"/>
			</mads:name>
			<xsl:call-template name="title"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=510]|marc:datafield[@tag=710]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<mads:name type="corporate">
				<xsl:call-template name="setAuthority"/>
				<xsl:call-template name="nameABCDN"/>
			</mads:name>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=511]|marc:datafield[@tag=711]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<mads:name type="conference">
				<xsl:call-template name="setAuthority"/>
				<xsl:call-template name="nameACDENQ"/>
			</mads:name>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>

	<!-- ========== titles  ========== -->
	<xsl:template match="marc:datafield[@tag=130]">
		<xsl:call-template name="uniform-title"/>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=430]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<xsl:call-template name="uniform-title"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:variant>
	</xsl:template>

	<xsl:template match="marc:datafield[@tag=530]|marc:datafield[@tag=730]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:call-template name="uniform-title"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>

	<xsl:template name="title">
		<xsl:variable name="hasTitle">
			<xsl:for-each select="marc:subfield">
				<xsl:if test="(contains('tfghklmors',@code) )">
					<xsl:value-of select="@code"/>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:if test="string-length($hasTitle) &gt; 0 ">
			<mads:titleInfo>
				<xsl:call-template name="setAuthority"/>
				<mads:title>
					<xsl:variable name="str">
						<xsl:for-each select="marc:subfield">
							<xsl:if test="(contains('atfghklmors',@code) )">
								<xsl:value-of select="text()"/>
								<xsl:text> </xsl:text>
							</xsl:if>
						</xsl:for-each>
					</xsl:variable>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="substring($str,1,string-length($str)-1)"/>
						</xsl:with-param>
					</xsl:call-template>
				</mads:title>
				<xsl:call-template name="part"/>
				<!-- <xsl:call-template name="uri"/> -->
			</mads:titleInfo>
		</xsl:if>
	</xsl:template>

	<xsl:template name="uniform-title">
		<xsl:variable name="hasTitle">
			<xsl:for-each select="marc:subfield">
				<xsl:if test="(contains('atfghklmors',@code) )">
					<xsl:value-of select="@code"/>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:if test="string-length($hasTitle) &gt; 0 ">
			<mads:titleInfo>
				<xsl:call-template name="setAuthority"/>
				<mads:title>
					<xsl:variable name="str">
						<xsl:for-each select="marc:subfield">
							<xsl:if test="(contains('adfghklmors',@code) )">
								<xsl:value-of select="text()"/>
								<xsl:text> </xsl:text>
							</xsl:if>
						</xsl:for-each>
					</xsl:variable>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="substring($str,1,string-length($str)-1)"/>
						</xsl:with-param>
					</xsl:call-template>
				</mads:title>
				<xsl:call-template name="part"/>
				<!-- <xsl:call-template name="uri"/> -->
			</mads:titleInfo>
		</xsl:if>
	</xsl:template>


	<!-- ========== topics  ========== -->
	<xsl:template match="marc:subfield[@code='x']">
		<mads:topic>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:value-of select="."/>
				</xsl:with-param>
			</xsl:call-template>
		</mads:topic>
	</xsl:template>
	
	<!-- 2.06 fix -->
	<xsl:template
		match="marc:datafield[@tag=150][marc:subfield[@code='a' or @code='b']]|marc:datafield[@tag=180][marc:subfield[@code='x']]">
		<xsl:call-template name="topic"/>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=450][marc:subfield[@code='a' or @code='b']]|marc:datafield[@tag=480][marc:subfield[@code='x']]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<xsl:call-template name="topic"/>
		</mads:variant>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=550 or @tag=750][marc:subfield[@code='a' or @code='b']]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<xsl:call-template name="topic"/>
			<xsl:apply-templates select="marc:subfield[@code='z']"/>
		</mads:related>
	</xsl:template>
	<xsl:template name="topic">
		<mads:topic>
			<xsl:call-template name="setAuthority"/>
			<!-- tmee2006 dedupe 550a
			<xsl:if test="@tag=550 or @tag=750">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</xsl:if>	
			-->
			<xsl:choose>
				<xsl:when test="@tag=180 or @tag=480 or @tag=580 or @tag=780">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:apply-templates select="marc:subfield[@code='x']"/>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:when>
			</xsl:choose>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:choose>
						<xsl:when test="@tag=180 or @tag=480 or @tag=580 or @tag=780">
							<xsl:apply-templates select="marc:subfield[@code='x']"/>
						</xsl:when>
						<xsl:otherwise>
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">ab</xsl:with-param>
							</xsl:call-template>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:with-param>
			</xsl:call-template>
		</mads:topic>
	</xsl:template>

	<!-- ========= temporals  ========== -->
	<xsl:template match="marc:subfield[@code='y']">
		<mads:temporal>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:value-of select="."/>
				</xsl:with-param>
			</xsl:call-template>
		</mads:temporal>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=148][marc:subfield[@code='a']]|marc:datafield[@tag=182 ][marc:subfield[@code='y']]">
		<xsl:call-template name="temporal"/>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=448][marc:subfield[@code='a']]|marc:datafield[@tag=482][marc:subfield[@code='y']]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<xsl:call-template name="temporal"/>
		</mads:variant>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=548 or @tag=748][marc:subfield[@code='a']]|marc:datafield[@tag=582 or @tag=782][marc:subfield[@code='y']]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<xsl:call-template name="temporal"/>
		</mads:related>
	</xsl:template>
	<xsl:template name="temporal">
		<mads:temporal>
			<xsl:call-template name="setAuthority"/>
			<xsl:if test="@tag=548 or @tag=748">
				<xsl:value-of select="marc:subfield[@code='a']"/>
			</xsl:if>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:choose>
						<xsl:when test="@tag=182 or @tag=482 or @tag=582 or @tag=782">
							<xsl:apply-templates select="marc:subfield[@code='y']"/>
						</xsl:when>
						<xsl:otherwise>
							<xsl:value-of select="marc:subfield[@code='a']"/>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:with-param>
			</xsl:call-template>
		</mads:temporal>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>

	<!-- ========== genre  ========== -->
	<xsl:template match="marc:subfield[@code='v']">
		<mads:genre>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:value-of select="."/>
				</xsl:with-param>
			</xsl:call-template>
		</mads:genre>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=155][marc:subfield[@code='a']]|marc:datafield[@tag=185][marc:subfield[@code='v']]">
		<xsl:call-template name="genre"/>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=455][marc:subfield[@code='a']]|marc:datafield[@tag=485 ][marc:subfield[@code='v']]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<xsl:call-template name="genre"/>
		</mads:variant>
	</xsl:template>
	<!--
	<xsl:template match="marc:datafield[@tag=555]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:call-template name="uri"/>
			<xsl:call-template name="genre"/>
		</mads:related>
	</xsl:template>
	-->
	<xsl:template
		match="marc:datafield[@tag=555 or @tag=755][marc:subfield[@code='a']]|marc:datafield[@tag=585][marc:subfield[@code='v']]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:call-template name="genre"/>
		</mads:related>
	</xsl:template>
	<xsl:template name="genre">
		<mads:genre>
			<xsl:if test="@tag=555">
				<xsl:value-of select="marc:subfield[@code='a']"/>
			</xsl:if>
			<xsl:call-template name="setAuthority"/>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:choose>
						<!-- 2.07 fix -->
						<xsl:when test="@tag='555'"/>
						<xsl:when test="@tag=185 or @tag=485 or @tag=585">
							<xsl:apply-templates select="marc:subfield[@code='v']"/>
						</xsl:when>
						<xsl:otherwise>
							<xsl:value-of select="marc:subfield[@code='a']"/>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:with-param>
			</xsl:call-template>
		</mads:genre>
		<xsl:apply-templates/>
	</xsl:template>

	<!-- ========= geographic  ========== -->
	<xsl:template match="marc:subfield[@code='z']">
		<mads:geographic>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:value-of select="."/>
				</xsl:with-param>
			</xsl:call-template>
		</mads:geographic>
	</xsl:template>
	<xsl:template name="geographic">
		<mads:geographic>
			<!-- 2.14 -->
			<xsl:call-template name="setAuthority"/>
			<!-- 2.13 -->
			<xsl:if test="@tag=151 or @tag=551">
				<xsl:value-of select="marc:subfield[@code='a']"/>
			</xsl:if>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
						<xsl:if test="@tag=181 or @tag=481 or @tag=581">
								<xsl:apply-templates select="marc:subfield[@code='z']"/>
						</xsl:if>
						<!-- 2.13
							<xsl:choose>
						<xsl:when test="@tag=181 or @tag=481 or @tag=581">
							<xsl:apply-templates select="marc:subfield[@code='z']"/>
						</xsl:when>
					
						<xsl:otherwise>
							<xsl:value-of select="marc:subfield[@code='a']"/>
						</xsl:otherwise>
						</xsl:choose>
						-->
				</xsl:with-param>
			</xsl:call-template>
		</mads:geographic>
		<xsl:apply-templates select="marc:subfield[@code!='i']"/>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=151][marc:subfield[@code='a']]|marc:datafield[@tag=181][marc:subfield[@code='z']]">
		<xsl:call-template name="geographic"/>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=451][marc:subfield[@code='a']]|marc:datafield[@tag=481][marc:subfield[@code='z']]">
		<mads:variant>
			<xsl:call-template name="variantTypeAttribute"/>
			<xsl:call-template name="geographic"/>
		</mads:variant>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=551]|marc:datafield[@tag=581][marc:subfield[@code='z']]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<!-- <xsl:call-template name="uri"/> -->
			<xsl:call-template name="geographic"/>
		</mads:related>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=580]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>
	<xsl:template
		match="marc:datafield[@tag=751][marc:subfield[@code='z']]|marc:datafield[@tag=781][marc:subfield[@code='z']]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:call-template name="geographic"/>
		</mads:related>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=755]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:call-template name="setAuthority"/>
			<xsl:call-template name="genre"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=780]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=785]">
		<mads:related>
			<xsl:call-template name="relatedTypeAttribute"/>
			<xsl:apply-templates select="marc:subfield[@code!='i']"/>
		</mads:related>
	</xsl:template>

	<!-- ========== notes  ========== -->
	<xsl:template match="marc:datafield[667 &lt;= @tag and @tag &lt;= 688]">
		<mads:note>
			<xsl:choose>
				<xsl:when test="@tag=667">
					<xsl:attribute name="type">nonpublic</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=670">
					<xsl:attribute name="type">source</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=675">
					<xsl:attribute name="type">notFound</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=678">
					<xsl:attribute name="type">history</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=681">
					<xsl:attribute name="type">subject example</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=682">
					<xsl:attribute name="type">deleted heading information</xsl:attribute>
				</xsl:when>
				<xsl:when test="@tag=688">
					<xsl:attribute name="type">application history</xsl:attribute>
				</xsl:when>
			</xsl:choose>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:choose>
						<xsl:when test="@tag=667 or @tag=675">
							<xsl:value-of select="marc:subfield[@code='a']"/>
						</xsl:when>
						<xsl:when test="@tag=670 or @tag=678">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">ab</xsl:with-param>
							</xsl:call-template>
						</xsl:when>
						<xsl:when test="680 &lt;= @tag and @tag &lt;=688">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">ai</xsl:with-param>
							</xsl:call-template>
						</xsl:when>
					</xsl:choose>
				</xsl:with-param>
			</xsl:call-template>
		</mads:note>
	</xsl:template>

	<!-- ========== url  ========== -->
	<xsl:template match="marc:datafield[@tag=856][marc:subfield[@code='u']]">
		<mads:url>
			<xsl:if test="marc:subfield[@code='z' or @code='3']">
				<xsl:attribute name="displayLabel">
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">z3</xsl:with-param>
					</xsl:call-template>
				</xsl:attribute>
			</xsl:if>
			<xsl:value-of select="marc:subfield[@code='u']"/>
		</mads:url>
	</xsl:template>

	<xsl:template name="relatedTypeAttribute">
		<xsl:choose>
			<xsl:when
				test="@tag=500 or @tag=510 or @tag=511 or @tag=548 or @tag=550 or @tag=551 or @tag=555 or @tag=580 or @tag=581 or @tag=582 or @tag=585">
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='a'">
					<xsl:attribute name="type">earlier</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='b'">
					<xsl:attribute name="type">later</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='t'">
					<xsl:attribute name="type">parentOrg</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='g'">
					<xsl:attribute name="type">broader</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='h'">
					<xsl:attribute name="type">narrower</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='r'">
					<xsl:attribute name="type">other</xsl:attribute>
				</xsl:if>
				<xsl:if test="contains('fin|', substring(marc:subfield[@code='w'],1,1))">
					<xsl:attribute name="type">other</xsl:attribute>
				</xsl:if>
			</xsl:when>
			<xsl:when test="@tag=530 or @tag=730">
				<xsl:attribute name="type">other</xsl:attribute>
			</xsl:when>
			<xsl:otherwise>
				<!-- 7xx -->
				<xsl:attribute name="type">equivalent</xsl:attribute>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:apply-templates select="marc:subfield[@code='i']"/>
	</xsl:template>
	


	<xsl:template name="variantTypeAttribute">
		<xsl:choose>
			<xsl:when
				test="@tag=400 or @tag=410 or @tag=411 or @tag=451 or @tag=455 or @tag=480 or @tag=481 or @tag=482 or @tag=485">
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='d'">
					<xsl:attribute name="type">acronym</xsl:attribute>
				</xsl:if>
				<xsl:if test="substring(marc:subfield[@code='w'],1,1)='n'">
					<xsl:attribute name="type">other</xsl:attribute>
				</xsl:if>
				<xsl:if test="contains('fit', substring(marc:subfield[@code='w'],1,1))">
					<xsl:attribute name="type">other</xsl:attribute>
				</xsl:if>
			</xsl:when>
			<xsl:otherwise>
				<!-- 430  -->
				<xsl:attribute name="type">other</xsl:attribute>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:apply-templates select="marc:subfield[@code='i']"/>
	</xsl:template>

	<xsl:template name="setAuthority">
		<xsl:choose>
			<!-- can be called from the datafield or subfield level, so "..//@tag" means
			the tag can be at the subfield's parent level or at the datafields own level -->

			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=100 and (@ind1=0 or @ind1=1) and $controlField008-11='a' and $controlField008-14='a'">
				<xsl:attribute name="authority">
					<xsl:text>naf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=100 and (@ind1=0 or @ind1=1) and $controlField008-11='a' and $controlField008-14='b'">
				<xsl:attribute name="authority">
					<xsl:text>lcsh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=100 and (@ind1=0 or @ind1=1) and $controlField008-11='k'">
				<xsl:attribute name="authority">
					<xsl:text>lacnaf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=100 and @ind1=3 and $controlField008-11='a' and $controlField008-14='b'">
				<xsl:attribute name="authority">
					<xsl:text>lcsh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=100 and @ind1=3 and $controlField008-11='k' and $controlField008-14='b'">
				<xsl:attribute name="authority">cash</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=110 and $controlField008-11='a' and $controlField008-14='a'">
				<xsl:attribute name="authority">naf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=110 and $controlField008-11='a' and $controlField008-14='b'">
				<xsl:attribute name="authority">lcsh</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=110 and $controlField008-11='k' and $controlField008-14='a'">
				<xsl:attribute name="authority">
					<xsl:text>lacnaf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=110 and $controlField008-11='k' and $controlField008-14='b'">
				<xsl:attribute name="authority">
					<xsl:text>cash</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="100 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 155 and $controlField008-11='b'">
				<xsl:attribute name="authority">
					<xsl:text>lcshcl</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=100 or ancestor-or-self::marc:datafield/@tag=110 or ancestor-or-self::marc:datafield/@tag=111 or ancestor-or-self::marc:datafield/@tag=130 or ancestor-or-self::marc:datafield/@tag=151) and $controlField008-11='c'">
				<xsl:attribute name="authority">
					<xsl:text>nlmnaf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=100 or ancestor-or-self::marc:datafield/@tag=110 or ancestor-or-self::marc:datafield/@tag=111 or ancestor-or-self::marc:datafield/@tag=130 or ancestor-or-self::marc:datafield/@tag=151) and $controlField008-11='d'">
				<xsl:attribute name="authority">
					<xsl:text>nalnaf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="100 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 155 and $controlField008-11='r'">
				<xsl:attribute name="authority">
					<xsl:text>aat</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="100 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 155 and $controlField008-11='s'">
				<xsl:attribute name="authority">sears</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="100 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 155 and $controlField008-11='v'">
				<xsl:attribute name="authority">rvm</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="100 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 155 and $controlField008-11='z'">
				<xsl:attribute name="authority">
					<xsl:value-of
						select="../marc:datafield[ancestor-or-self::marc:datafield/@tag=040]/marc:subfield[@code='f']"
					/>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=111 or ancestor-or-self::marc:datafield/@tag=130) and $controlField008-11='a' and $controlField008-14='a'">
				<xsl:attribute name="authority">
					<xsl:text>naf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=111 or ancestor-or-self::marc:datafield/@tag=130) and $controlField008-11='a' and $controlField008-14='b'">
				<xsl:attribute name="authority">
					<xsl:text>lcsh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=111 or ancestor-or-self::marc:datafield/@tag=130) and $controlField008-11='k' ">
				<xsl:attribute name="authority">
					<xsl:text>lacnaf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=148 or ancestor-or-self::marc:datafield/@tag=150  or ancestor-or-self::marc:datafield/@tag=155) and $controlField008-11='a' ">
				<xsl:attribute name="authority">
					<xsl:text>lcsh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=148 or ancestor-or-self::marc:datafield/@tag=150  or ancestor-or-self::marc:datafield/@tag=155) and $controlField008-11='a' ">
				<xsl:attribute name="authority">
					<xsl:text>lcsh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=148 or ancestor-or-self::marc:datafield/@tag=150  or ancestor-or-self::marc:datafield/@tag=155) and $controlField008-11='c' ">
				<xsl:attribute name="authority">
					<xsl:text>mesh</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=148 or ancestor-or-self::marc:datafield/@tag=150  or ancestor-or-self::marc:datafield/@tag=155) and $controlField008-11='d' ">
				<xsl:attribute name="authority">
					<xsl:text>nal</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=148 or ancestor-or-self::marc:datafield/@tag=150  or ancestor-or-self::marc:datafield/@tag=155) and $controlField008-11='k' ">
				<xsl:attribute name="authority">
					<xsl:text>cash</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=151 and $controlField008-11='a' and $controlField008-14='a'">
				<xsl:attribute name="authority">
					<xsl:text>naf</xsl:text>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=151 and $controlField008-11='a' and $controlField008-14='b'">
				<xsl:attribute name="authority">lcsh</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=151 and $controlField008-11='k' and $controlField008-14='a'">
				<xsl:attribute name="authority">lacnaf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=151 and $controlField008-11='k' and $controlField008-14='b'">
				<xsl:attribute name="authority">cash</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(..//ancestor-or-self::marc:datafield/@tag=180 or ..//ancestor-or-self::marc:datafield/@tag=181 or ..//ancestor-or-self::marc:datafield/@tag=182 or ..//ancestor-or-self::marc:datafield/@tag=185) and $controlField008-11='a'">
				<xsl:attribute name="authority">lcsh</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=700 and (@ind1='0' or @ind1='1') and @ind2='0'">
				<xsl:attribute name="authority">naf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="ancestor-or-self::marc:datafield/@tag=700 and (@ind1='0' or @ind1='1') and @ind2='5'">
				<xsl:attribute name="authority">lacnaf</xsl:attribute>
			</xsl:when>
			<xsl:when test="ancestor-or-self::marc:datafield/@tag=700 and @ind1='3' and @ind2='0'">
				<xsl:attribute name="authority">lcsh</xsl:attribute>
			</xsl:when>
			<xsl:when test="ancestor-or-self::marc:datafield/@tag=700 and @ind1='3' and @ind2='5'">
				<xsl:attribute name="authority">cash</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(700 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 755 ) and @ind2='1'">
				<xsl:attribute name="authority">lcshcl</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=700 or ancestor-or-self::marc:datafield/@tag=710 or ancestor-or-self::marc:datafield/@tag=711 or ancestor-or-self::marc:datafield/@tag=730 or ancestor-or-self::marc:datafield/@tag=751)  and @ind2='2'">
				<xsl:attribute name="authority">nlmnaf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=700 or ancestor-or-self::marc:datafield/@tag=710 or ancestor-or-self::marc:datafield/@tag=711 or ancestor-or-self::marc:datafield/@tag=730 or ancestor-or-self::marc:datafield/@tag=751)  and @ind2='3'">
				<xsl:attribute name="authority">nalnaf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(700 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 755 ) and @ind2='6'">
				<xsl:attribute name="authority">rvm</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(700 &lt;= ancestor-or-self::marc:datafield/@tag and ancestor-or-self::marc:datafield/@tag &lt;= 755 ) and @ind2='7'">
				<xsl:attribute name="authority">
					<xsl:value-of select="marc:subfield[@code='2']"/>
				</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=710 or ancestor-or-self::marc:datafield/@tag=711 or ancestor-or-self::marc:datafield/@tag=730 or ancestor-or-self::marc:datafield/@tag=751)  and @ind2='5'">
				<xsl:attribute name="authority">lacnaf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=710 or ancestor-or-self::marc:datafield/@tag=711 or ancestor-or-self::marc:datafield/@tag=730 or ancestor-or-self::marc:datafield/@tag=751)  and @ind2='0'">
				<xsl:attribute name="authority">naf</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=748 or ancestor-or-self::marc:datafield/@tag=750 or ancestor-or-self::marc:datafield/@tag=755)  and @ind2='0'">
				<xsl:attribute name="authority">lcsh</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=748 or ancestor-or-self::marc:datafield/@tag=750 or ancestor-or-self::marc:datafield/@tag=755)  and @ind2='2'">
				<xsl:attribute name="authority">mesh</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=748 or ancestor-or-self::marc:datafield/@tag=750 or ancestor-or-self::marc:datafield/@tag=755)  and @ind2='3'">
				<xsl:attribute name="authority">nal</xsl:attribute>
			</xsl:when>
			<xsl:when
				test="(ancestor-or-self::marc:datafield/@tag=748 or ancestor-or-self::marc:datafield/@tag=750 or ancestor-or-self::marc:datafield/@tag=755)  and @ind2='5'">
				<xsl:attribute name="authority">cash</xsl:attribute>
			</xsl:when>
		</xsl:choose>
	</xsl:template>
	<xsl:template match="*"/>
</xsl:stylesheet>$XSLT$ WHERE name = 'mads21';

COMMIT;

-- Update auditor tables to catch changes to source tables.
--   Can be removed/skipped if there were no schema changes.
SELECT auditor.update_auditors();
