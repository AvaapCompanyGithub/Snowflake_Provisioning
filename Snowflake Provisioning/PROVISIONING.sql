use role SYSADMIN;
use warehouse ADMIN_WH;
use UTIL_DB.ADMIN;

--------------------------------------------------
--SAMPLE CALLS

SP_PROVISION_DB(DB_NAME, RETENTION);
SP_PROVISION_SCHEMA(DB_NAME, SCHEMA_NAME);
SP_GRANT_DBSCH_ACCESS(DB_NAME, SCHEMA_NAME, ROLE_NAME, ACCESS_TYPE, CREATE_ROLE, WH_NAME, ADMIN_ROLES);

--------------------------------------------------
--DATABASE

use role SYSADMIN;

create or replace procedure UTIL_DB.ADMIN.SP_PROVISION_DB(DB_NAME varchar, RETENTION number)
returns variant
language sql
execute as owner
as
$$
declare
    db           varchar;
    days         number;
    admin_role   varchar;
    exists_flag  boolean default true;
    step         varchar default 'start';
    return_msg   variant default '';
    ident_rx     varchar default '^[A-Za-z_][A-Za-z0-9_]*$';
    bad_name     exception (-20001, 'Invalid Database Name: letters, digits and underscores only. Must start with a letter or underscore.');
begin

    -- Variables
    db := upper(trim(DB_NAME));
    admin_role := db || '.' || db || '_ADMIN';
    days := least(greatest(floor(coalesce(RETENTION, 1)), 1), 90); --Clamp to 1..90

    -- Check DB name
    step := 'Validate name ' || db;
    if (not regexp_like(db, ident_rx)) then
        raise bad_name;
    end if;
 
    -- Check if database exists (LIKE treats _ as a wildcard, so also match the exact name)
    step := 'Check if database exists ' || db;
    execute immediate
        'show databases like ''' || db || '''
            ->> select count(*) > 0 from $1 where "name" = ''' || db || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    -- Create database if missing. If it already exists, just update the retention.
    if (exists_flag) then
        step := 'Alter database ' || db;
        execute immediate 'alter database ' || db || ' set data_retention_time_in_days = ' || days;
    else
        step := 'Create database ' || db;
        execute immediate 'create database ' || db || ' data_retention_time_in_days = ' || days;
    end if;
 
    -- Admin database role (owned by SYSADMIN via owner's rights)
    step := 'Create database role ' || admin_role;
    execute immediate 'create database role if not exists ' || admin_role;

    -- Grant Privileges
    step := 'Grant privileges to role ' || admin_role;
    execute immediate 'grant usage, monitor, create schema on database ' || db || ' to database role ' || admin_role;

    --------------------------------------------------------------------
    -- Completed
    --------------------------------------------------------------------
    
    return_msg := iff(exists_flag,
                   'Database ' || db || ' already existed. Retention set to ' || days || ' day(s).',
                   'Database ' || db || ' created (data_retention_time_in_days = ' || days || ').');

    return object_construct(
        'status',  'SUCCESS',
        'message', :return_msg,
        'details', object_construct(
                       'database_name',  :db,
                       'data_retention', :days,
                       'db_admin_role',  :admin_role
                   )
    );

    exception
        when other then
            return object_construct(
                'status',   'ERROR',
                'sqlcode',  sqlcode,
                'sqlstate', sqlstate,
                'message',  sqlerrm,
                'details',  object_construct(
                                'step',           :step,
                                'database_name',  :db,
                                'data_retention', :days,
                                'db_admin_role',  :admin_role
                            )
            );
end;
$$;

--------------------------------------------------
--SCHEMA

use role SYSADMIN;

create or replace procedure UTIL_DB.ADMIN.SP_PROVISION_SCHEMA(DB_NAME varchar, SCHEMA_NAME varchar)
returns variant
language sql
execute as owner
as
$$
declare
    db           varchar;
    sch          varchar;
    fq_sch       varchar;
    ro_role      varchar;
    rw_role      varchar;
    gov_role     varchar;
    ai_role      varchar;
    app_role     varchar;
    exists_flag  boolean default false;
    skipped      array default array_construct();
    step         varchar default 'start';
    return_msg   variant default '';
    ident_rx     varchar default '^[A-Za-z_][A-Za-z0-9_]*$';
    bad_name     exception (-20001, 'Invalid Schema Name: letters, digits and underscores only. Must start with a letter or underscore.');
    db_not_found exception (-20002, 'Database does not exist. Please create it first.');
    bad_db_name  exception (-20003, 'Invalid Database Name: letters, digits and underscores only. Must start with a letter or underscore.');

begin

    -- Variables
    db := upper(trim(DB_NAME));
    sch := upper(trim(SCHEMA_NAME));
    fq_sch := db || '.' || sch;
    ro_role  := db || '.' || db || '_' || sch || '_RO';
    rw_role  := db || '.' || db || '_' || sch || '_RW';
    gov_role := db || '.' || db || '_' || sch || '_GOV';
    ai_role  := db || '.' || db || '_' || sch || '_AI';
    app_role := db || '.' || db || '_' || sch || '_APP';

    -- Check Database name (it is concatenated into SQL below)
    step := 'Validate name ' || db;
    if (not regexp_like(db, ident_rx)) then
        raise bad_db_name;
    end if;

    -- Check Schema name
    step := 'Validate name ' || sch;
    if (not regexp_like(sch, ident_rx)) then
        raise bad_name;
    end if;

    -- Check if database exists (LIKE treats _ as a wildcard, so also match the exact name)
    step := 'Check if database exists ' || db;
    execute immediate
        'show databases like ''' || db || '''
            ->> select count(*) > 0 from $1 where "name" = ''' || db || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    if (not exists_flag) then
        raise db_not_found;
    end if;

    -- Check if schema exists
    step := 'Check if schema exists ' || sch;
    execute immediate
        'show schemas like ''' || sch || ''' in database ' || db || '
            ->> select count(*) > 0 from $1 where "name" = ''' || sch || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    -- Create Schema (owned by SYSADMIN, managed access)
    step := 'Create schema ' || sch;
    execute immediate 'create schema if not exists ' || fq_sch || ' with managed access';

    -- Roles (owned by SYSADMIN via owner's rights)
    step := 'Create database roles for schema ' || sch;
    execute immediate 'create database role if not exists ' || ro_role;
    execute immediate 'create database role if not exists ' || rw_role;
    execute immediate 'create database role if not exists ' || gov_role;
    execute immediate 'create database role if not exists ' || ai_role;
    execute immediate 'create database role if not exists ' || app_role;

    --------------------------------------------------------------------
    -- Read Only : usage on db + schema, select on readable objects.
    --------------------------------------------------------------------
    step := 'RO - Grant usage in database/schema ' || fq_sch;
    execute immediate 'grant usage on database ' || db     || ' to database role ' || ro_role;
    execute immediate 'grant usage on schema '   || fq_sch || ' to database role ' || ro_role;

    -- SELECT on tables, views and streams
    let ro_sel array := array_construct(
        'tables', 'hybrid tables',
        'views', 'materialized views', 'semantic views',
        'dynamic tables', 'external tables', 'iceberg tables', 'streams');
    for i in 0 to array_size(ro_sel) - 1 do
        let o varchar := get(ro_sel, i)::varchar;
        begin
            step := 'RO - Grant select on ' || o;
            execute immediate 'grant select on all '    || o || ' in schema ' || fq_sch || ' to database role ' || ro_role;
            execute immediate 'grant select on future ' || o || ' in schema ' || fq_sch || ' to database role ' || ro_role;
        exception
            when other then
                skipped := array_append(skipped, 'RO select: ' || o);
        end;
    end for;

    -- USAGE on streamlits (app runs via USAGE, not SELECT)
    begin
        step := 'RO - Grant usage on streamlits';
        execute immediate 'grant usage on all streamlits in schema '    || fq_sch || ' to database role ' || ro_role;
        execute immediate 'grant usage on future streamlits in schema ' || fq_sch || ' to database role ' || ro_role;
    exception
        when other then
            skipped := array_append(skipped, 'RO usage: streamlits');
    end;

    --------------------------------------------------------------------
    -- Read Write : usage on db + schema, read + DML + execute + loading
    --------------------------------------------------------------------
    step := 'RW - Grant usage in database/schema ' || fq_sch;
    execute immediate 'grant usage on database ' || db     || ' to database role ' || rw_role;
    execute immediate 'grant usage on schema '   || fq_sch || ' to database role ' || rw_role;

    -- SELECT on read-only object types (tables/hybrid handled by DML below)
    let rw_sel array := array_construct(
        'views', 'materialized views', 'semantic views',
        'dynamic tables', 'external tables', 'iceberg tables', 'streams');
    for i in 0 to array_size(rw_sel) - 1 do
        let o varchar := get(rw_sel, i)::varchar;
        begin
            step := 'RW - Grant select on ' || o;
            execute immediate 'grant select on all '    || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
            execute immediate 'grant select on future ' || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
        exception
            when other then
                skipped := array_append(skipped, 'RW select: ' || o);
        end;
    end for;

    -- DML on tables + hybrid tables (hybrid bulk form may be unsupported)
    let rw_dml array := array_construct('tables', 'hybrid tables');
    for i in 0 to array_size(rw_dml) - 1 do
        let o varchar := get(rw_dml, i)::varchar;
        begin
            step := 'RW - Grant sel/ins/upd/del/trunc on ' || o;
            execute immediate 'grant select, insert, update, delete, truncate on all '    || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
            execute immediate 'grant select, insert, update, delete, truncate on future ' || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
        exception
            when other then
                skipped := array_append(skipped, 'RW dml: ' || o);
        end;
    end for;

    -- Usage / execute: sequences, code objects, file formats, apps
    let rw_usage array := array_construct(
        'sequences', 'functions', 'procedures', 'file formats',
        'streamlits');
    for i in 0 to array_size(rw_usage) - 1 do
        let o varchar := get(rw_usage, i)::varchar;
        begin
            step := 'RW - Grant usage on ' || o;
            execute immediate 'grant usage on all '    || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
            execute immediate 'grant usage on future ' || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
        exception
            when other then
                skipped := array_append(skipped, 'RW usage: ' || o);
        end;
    end for;

    -- Internal stage read/write
    step := 'RW - Grant r/w on stages';
    execute immediate 'grant read, write on all stages in schema '    || fq_sch || ' to database role ' || rw_role;
    execute immediate 'grant read, write on future stages in schema ' || fq_sch || ' to database role ' || rw_role;

    -- OPERATE/MONITOR on pipes RW creates later (future only - no ALL form)
    begin
        step := 'RW - Grant op/mon pipes';
        execute immediate 'grant operate, monitor on future pipes in schema ' || fq_sch || ' to database role ' || rw_role;
    exception
        when other then
            skipped := array_append(skipped, 'RW pipe ops: future pipes');
    end;

    -- CREATE on the schema: RW is the working role that builds objects
    let rw_create array := array_construct(
        'table', 'hybrid table', 'dynamic table', 'external table', 'iceberg table', 'event table',
        'view', 'materialized view', 'semantic view',
        'agent', 'cortex search service', 'model',
        'sequence', 'function', 'procedure',
        'stage', 'file format',
        'stream', 'task', 'alert', 'pipe',
        'streamlit', 'workspace', 'notebook project');
    for i in 0 to array_size(rw_create) - 1 do
        let o varchar := get(rw_create, i)::varchar;
        begin
            step := 'RW - Grant create ' || o;
            execute immediate 'grant create ' || o || ' on schema ' || fq_sch || ' to database role ' || rw_role;
        exception
            when other then
                skipped := array_append(skipped, 'RW create: ' || o);
        end;
    end for;

    -- AI objects: use / modify / operate / monitor on objects other roles created.
    -- One grant per privilege so an unsupported combination only skips itself.
    let rw_ai object := object_construct(
        'agents',                  array_construct('usage', 'modify', 'monitor'),
        'cortex search services',  array_construct('usage', 'operate', 'monitor'),
        'models',                  array_construct('usage', 'monitor'),
        'semantic views',          array_construct('references'));  -- SELECT + REFERENCES needed to use in Cortex Analyst
    let rw_ai_keys array := object_keys(rw_ai);
    for i in 0 to array_size(rw_ai_keys) - 1 do
        let o varchar := get(rw_ai_keys, i)::varchar;
        let privs array := get(rw_ai, o)::array;
        for j in 0 to array_size(privs) - 1 do
            let p varchar := get(privs, j)::varchar;
            begin
                step := 'RW - Grant ' || p || ' on ' || o;
                execute immediate 'grant ' || p || ' on all '    || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
                execute immediate 'grant ' || p || ' on future ' || o || ' in schema ' || fq_sch || ' to database role ' || rw_role;
            exception
                when other then
                    skipped := array_append(skipped, 'RW ' || p || ': ' || o);
            end;
        end for;
    end for;

    --------------------------------------------------------------------
    -- Governance : usage on db + schema, create policy/tag objects.
    --------------------------------------------------------------------
    step := 'GOV - Grant usage in database/schema ' || fq_sch;
    execute immediate 'grant usage on database ' || db     || ' to database role ' || gov_role;
    execute immediate 'grant usage on schema '   || fq_sch || ' to database role ' || gov_role;

    let gov_create array := array_construct('masking policy', 'row access policy', 'tag');
    for i in 0 to array_size(gov_create) - 1 do
        let o varchar := get(gov_create, i)::varchar;
        begin
            step := 'GOV - Grant create ' || o;
            execute immediate 'grant create ' || o || ' on schema ' || fq_sch || ' to database role ' || gov_role;
        exception
            when other then
                skipped := array_append(skipped, 'GOV create: ' || o);
        end;
    end for;

    --------------------------------------------------------------------
    -- AI : read-only access through AI only (agents, Cortex Analyst,
    -- Cortex Search). No direct SELECT on tables/views.
    -- Querying a semantic view doesn't need SELECT on its base tables.
    -- Account-level AI rights (Cortex, AI functions, Snowflake
    -- Intelligence) come from the AI_USER role, not from here.
    --------------------------------------------------------------------
    step := 'AI - Grant usage in database/schema ' || fq_sch;
    execute immediate 'grant usage on database ' || db     || ' to database role ' || ai_role;
    execute immediate 'grant usage on schema '   || fq_sch || ' to database role ' || ai_role;

    -- Earlier versions had AI inherit RO - remove that on re-provision
    begin
        step := 'AI - Revoke inherited RO';
        execute immediate 'revoke database role ' || ro_role || ' from database role ' || ai_role;
    exception
        when other then null;  -- not granted
    end;

    let ai_usage array := array_construct('agents', 'cortex search services');
    for i in 0 to array_size(ai_usage) - 1 do
        let o varchar := get(ai_usage, i)::varchar;
        begin
            step := 'AI - Grant usage on ' || o;
            execute immediate 'grant usage on all '    || o || ' in schema ' || fq_sch || ' to database role ' || ai_role;
            execute immediate 'grant usage on future ' || o || ' in schema ' || fq_sch || ' to database role ' || ai_role;
        exception
            when other then
                skipped := array_append(skipped, 'AI usage: ' || o);
        end;
    end for;

    -- Semantic views: Cortex Analyst needs SELECT + REFERENCES
    begin
        step := 'AI - Grant select, references on semantic views';
        execute immediate 'grant select, references on all semantic views in schema '    || fq_sch || ' to database role ' || ai_role;
        execute immediate 'grant select, references on future semantic views in schema ' || fq_sch || ' to database role ' || ai_role;
    exception
        when other then
            skipped := array_append(skipped, 'AI select/references: semantic views');
    end;

    --------------------------------------------------------------------
    -- App : view Streamlit apps only. Apps run with owner's rights,
    -- so no access to the underlying data is needed.
    --------------------------------------------------------------------
    step := 'APP - Grant usage in database/schema ' || fq_sch;
    execute immediate 'grant usage on database ' || db     || ' to database role ' || app_role;
    execute immediate 'grant usage on schema '   || fq_sch || ' to database role ' || app_role;

    begin
        step := 'APP - Grant usage on streamlits';
        execute immediate 'grant usage on all streamlits in schema '    || fq_sch || ' to database role ' || app_role;
        execute immediate 'grant usage on future streamlits in schema ' || fq_sch || ' to database role ' || app_role;
    exception
        when other then
            skipped := array_append(skipped, 'APP usage: streamlits');
    end;

    --------------------------------------------------------------------
    -- Completed
    --------------------------------------------------------------------

    return_msg := iff(exists_flag,
                   'Schema ' || fq_sch || ' already existed - skipped creation. '
                   || 'If it is not managed access, convert it manually: '
                   || 'alter schema ' || fq_sch || ' enable managed access;',
                   'Schema ' || fq_sch || ' created.');

    return object_construct(
        'status',  'SUCCESS',
        'message', :return_msg,
        'details', object_construct(
                       'database_name',  :db,
                       'db_schema_name', :sch,
                       'roles',          array_construct(ro_role, rw_role, gov_role, ai_role, app_role),
                       'skipped_grants', object_construct('count', array_size(skipped), 'items', skipped)
                   )
    );

    exception
        when other then
            return object_construct(
                'status',   'ERROR',
                'sqlcode',  sqlcode,
                'sqlstate', sqlstate,
                'message',  sqlerrm,
                'details',  object_construct(
                                'step',          :step,
                                'database_name', :db,
                                'schema_name',   :sch
                            )
            );

end;
$$;


--------------------------------------------------
--GRANT ACCESS - owned by SECURITYADMIN

use role SECURITYADMIN;

--Old 5-parameter version (before WH_NAME / ADMIN_ROLES were added)
drop procedure if exists UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(varchar, varchar, varchar, varchar, boolean);

create or replace procedure UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(
    DB_NAME     varchar,
    SCHEMA_NAME varchar,
    ROLE_NAME   varchar,
    ACCESS_TYPE varchar,
    CREATE_ROLE boolean,
    WH_NAME     varchar,    -- optional: grant usage on this warehouse (skipped if null or not found)
    ADMIN_ROLES varchar     -- optional: JSON of ROLE_NAME : ACCESS_TYPE or [ACCESS_TYPE, ...], e.g. {"TASK_ADMIN": "RW", "AI_USER": ["AI", "RW"]}
)
returns variant
language sql
execute as owner
as
$$
declare
    db             varchar;
    sch            varchar;
    acct_role      varchar;
    access_lvl     varchar;
    sch_role       varchar;
    sch_role_name  varchar;
    sch_role_flag  boolean default false;
    create_flag    boolean;
    exists_flag    boolean default true;
    wh             varchar;
    wh_msg         varchar default '';
    wh_skipped     boolean default false;
    admin_obj      variant;
    admin_keys     array;
    is_admin       boolean default false;
    admin_flag     boolean default false;
    admin_todo     array default array_construct();
    admin_missing  array default array_construct();
    admin_granted  array default array_construct();
    admin_skipped  array default array_construct();
    step           varchar default 'start';
    return_msg     variant default '';
    ident_rx       varchar default '^[A-Za-z_][A-Za-z0-9_]*$';
    bad_name       exception (-20001, 'Invalid Role Name: letters, digits and underscores only. Must start with a letter or underscore.');
    bad_access     exception (-20002, 'ACCESS_TYPE must be RO, RW, GOV, AI or APP.');
    db_not_found   exception (-20003, 'Database does not exist. Please create it first.');
    sch_not_found  exception (-20004, 'Schema does not exist. Please create it first.');
    role_not_found exception (-20005, 'Role does not exist. Please create it first.');
    protected_role exception (-20006, 'Built-in Snowflake roles (ACCOUNTADMIN, SECURITYADMIN, USERADMIN, SYSADMIN, ORGADMIN, PUBLIC) are not allowed.');
    bad_db_name    exception (-20007, 'Invalid Database Name: letters, digits and underscores only. Must start with a letter or underscore.');
    bad_sch_name   exception (-20008, 'Invalid Schema Name: letters, digits and underscores only. Must start with a letter or underscore.');
    bad_admin_roles exception (-20009, 'ADMIN_ROLES must be a JSON object of ROLE_NAME : ACCESS_TYPE pairs.');
    admin_as_role  exception (-20010, 'Admin roles (listed in ADMIN_ROLES) are not allowed as ROLE_NAME.');
    sch_role_missing exception (-20011, 'This schema has no database role for that access type. Re-run Schema provisioning (step 2) on it to add the newer access types.');

begin
    db := upper(trim(coalesce(DB_NAME, '')));
    sch := upper(trim(coalesce(SCHEMA_NAME, '')));
    acct_role := upper(trim(coalesce(ROLE_NAME, '')));
    access_lvl := upper(trim(coalesce(ACCESS_TYPE, '')));
    sch_role_name := db || '_' || sch || '_' || access_lvl;
    sch_role := db || '.' || sch_role_name;
    create_flag := coalesce(CREATE_ROLE, false);
    wh := upper(trim(coalesce(WH_NAME, '')));
    admin_obj := coalesce(try_parse_json(nullif(trim(ADMIN_ROLES), '')), object_construct());

    --Check Role name
    step := 'Validate name ' || acct_role;
    if (not regexp_like(acct_role, ident_rx)) then
        raise bad_name;
    end if;

    --Check Database and Schema names (they are concatenated into SQL below, run as SECURITYADMIN)
    step := 'Validate name ' || db;
    if (not regexp_like(db, ident_rx)) then
        raise bad_db_name;
    end if;

    step := 'Validate name ' || sch;
    if (not regexp_like(sch, ident_rx)) then
        raise bad_sch_name;
    end if;

    --Built-in Snowflake roles are never allowed (hardcoded - not configurable)
    step := 'Check built-in roles';
    if (acct_role in ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC')) then
        raise protected_role;
    end if;

    --Access type check
    step := 'Validate access type';
    if (access_lvl not in ('RO', 'RW', 'GOV', 'AI', 'APP')) then
        raise bad_access;
    end if;

    --Admin roles check
    step := 'Validate admin roles';
    if (typeof(admin_obj) <> 'OBJECT') then
        raise bad_admin_roles;
    end if;

    --Admin roles can't receive schema access themselves
    step := 'Check admin roles';
    select count(*) > 0
    into :is_admin
    from table(flatten(input => :admin_obj))
    where upper(trim(key)) = :acct_role;

    if (is_admin) then
        raise admin_as_role;
    end if;

    -- Check if database exists (LIKE treats _ as a wildcard, so also match the exact name)
    step := 'Check if database exists ' || db;
    execute immediate
        'show databases like ''' || db || '''
            ->> select count(*) > 0 from $1 where "name" = ''' || db || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    if (not exists_flag) then
        raise db_not_found;
    end if;

    -- Check if schema exists
    step := 'Check if schema exists ' || sch;
    execute immediate
        'show schemas like ''' || sch || ''' in database ' || db || '
            ->> select count(*) > 0 from $1 where "name" = ''' || sch || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    if (not exists_flag) then
        raise sch_not_found;
    end if;

    -- Check the schema's database role for this access type exists
    -- (schemas provisioned before AI/APP were added won't have them yet)
    step := 'Check if database role exists ' || sch_role;
    execute immediate
        'show database roles like ''' || sch_role_name || ''' in database ' || db || '
            ->> select count(*) > 0 from $1 where "name" = ''' || sch_role_name || '''';
    select $1
    into :sch_role_flag
    from table(result_scan(last_query_id()));

    if (not sch_role_flag) then
        raise sch_role_missing;
    end if;

    --Check if role exists
    step := 'Check if role exists ' || acct_role;
    execute immediate
        'show roles like ''' || acct_role || '''
            ->> select count(*) > 0 from $1 where "name" = ''' || acct_role || '''';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    --If create is false but role doesn't exist, fail
    if (not create_flag and not exists_flag) then
        raise role_not_found;
    end if;

    -- Admin roles whose access type matches this grant (e.g. RW -> TASK_ADMIN).
    -- Value is one access type ("RW") or a list (["AI", "RW"]).
    -- All of them must exist before anything is changed - otherwise fail with nothing done.
    step := 'Check admin roles exist';
    admin_keys := object_keys(admin_obj);
    for i in 0 to array_size(admin_keys) - 1 do
        let r varchar := upper(trim(get(admin_keys, i)::varchar));
        let v variant := get(admin_obj, get(admin_keys, i)::varchar);
        let lvls varchar := ',' || upper(replace(iff(is_array(v), array_to_string(v::array, ','), v::varchar), ' ', '')) || ',';
        if (contains(lvls, ',' || access_lvl || ',')) then
            if (not regexp_like(r, ident_rx)) then
                admin_missing := array_append(admin_missing, r || ' (invalid name)');
            else
                execute immediate
                    'show roles like ''' || r || '''
                        ->> select count(*) > 0 from $1 where "name" = ''' || r || '''';
                select $1
                into :admin_flag
                from table(result_scan(last_query_id()));

                if (admin_flag) then
                    admin_todo := array_append(admin_todo, r);
                else
                    admin_missing := array_append(admin_missing, r);
                end if;
            end if;
        end if;
    end for;

    if (array_size(admin_missing) > 0) then
        return object_construct(
            'status',  'ERROR',
            'message', 'Admin role(s) not found: ' || array_to_string(admin_missing, ', ')
                       || '. Run ADMIN_ROLES.sql, or fix "admin_roles" in config.json. Nothing was changed.',
            'details', object_construct(
                           'step',                :step,
                           'database_name',       :db,
                           'schema_name',         :sch,
                           'role_name',           :acct_role,
                           'admin_roles_missing', :admin_missing
                       )
        );
    end if;

    --Create the account role if it doesn't exist, if desired
    if (create_flag) then
        step := 'Create role ' || acct_role;
        execute immediate 'create role if not exists ' || acct_role;
    end if;

    --Grant it to SYSADMIN and database role
    step := 'Grant role ' || acct_role || ' to other roles';
    execute immediate 'grant role ' || acct_role || ' to role SYSADMIN';
    execute immediate 'grant database role ' || sch_role || ' to role ' || acct_role;

    -- Grant the admin roles checked above.
    -- Intentional: these carry ACCOUNT-level privileges, not schema-scoped ones.
    for i in 0 to array_size(admin_todo) - 1 do
        let r varchar := get(admin_todo, i)::varchar;
        begin
            step := 'Grant admin role ' || r || ' to ' || acct_role;
            execute immediate 'grant role ' || r || ' to role ' || acct_role;
            admin_granted := array_append(admin_granted, r);
        exception
            when other then
                admin_skipped := array_append(admin_skipped, r || ' (' || sqlerrm || ')');
        end;
    end for;

    -- Optional warehouse usage (skipped if not given or not found)
    if (wh <> '') then
        if (not regexp_like(wh, ident_rx)) then
            wh_msg := ' Warehouse ' || wh || ' skipped (invalid name).';
            wh_skipped := true;
        else
            begin
                step := 'Grant usage on warehouse ' || wh;
                execute immediate 'grant usage on warehouse ' || wh || ' to role ' || acct_role;
                wh_msg := ' Granted usage on warehouse ' || wh || '.';
            exception
                when other then
                    wh_msg := ' Warehouse ' || wh || ' skipped: ' || sqlerrm;
                    wh_skipped := true;
            end;
        end if;
    end if;

    --------------------------------------------------------------------
    -- Completed
    --------------------------------------------------------------------
    
    return_msg := iff(exists_flag,
                   'Role ' || acct_role || ' already existed - skipped creation.',
                   'Role ' || acct_role || ' created.')
                  || ' Granted ' || sch_role || ' to ' || acct_role
                  || iff(array_size(admin_granted) > 0, ' (+ ' || array_to_string(admin_granted, ', ') || ')', '')
                  || '.'
                  || iff(array_size(admin_skipped) > 0, ' Skipped admin roles: ' || array_to_string(admin_skipped, ', ') || '.', '')
                  || wh_msg;

    -- WARNING = main grant done, but an admin role or the warehouse wasn't granted
    return object_construct(
        'status',  iff(array_size(admin_skipped) > 0 or wh_skipped, 'WARNING', 'SUCCESS'),
        'message', :return_msg,
        'details', object_construct(
                       'database_name',       :db,
                       'schema_name',         :sch,
                       'role_name',           :acct_role,
                       'warehouse',           nullif(:wh, ''),
                       'admin_roles_granted', :admin_granted,
                       'admin_roles_skipped', :admin_skipped
                   )
    );

    exception
        when other then
            return object_construct(
                'status',   'ERROR',
                'sqlcode',  sqlcode,
                'sqlstate', sqlstate,
                'message',  sqlerrm,
                'details',  object_construct(
                                'step',          :step,
                                'database_name', :db,
                                'schema_name',   :sch,
                                'role_name',     :acct_role
                            )
            );

end;
$$;

grant usage on procedure UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(varchar, varchar, varchar, varchar, boolean, varchar, varchar) to role SYSADMIN;
use role SYSADMIN;