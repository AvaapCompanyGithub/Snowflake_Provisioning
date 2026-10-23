use role SYSADMIN;
use warehouse ADMIN_WH;
use UTIL_DB.ADMIN;

--------------------------------------------------
--SAMPLE CALLS

SP_PROVISION_DB(DB_NAME, RETENTION);
SP_PROVISION_SCHEMA(DB_NAME, SCHEMA_NAME);
SP_GRANT_DBSCH_ACCESS(DB_NAME, SCHEMA_NAME, ROLE_NAME, ACCESS_TYPE, CREATE_ROLE);

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
 
    -- Create database if missing. If it already exists, just update the retention.
    step := 'Create/alter database';
    begin
        execute immediate 'alter database ' || db || ' set data_retention_time_in_days = ' || days;
    exception
        when other then
            execute immediate 'create database if not exists ' || db || ' data_retention_time_in_days = ' || days;
            exists_flag := false;
    end;
 
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
    exists_flag  boolean default false;
    skipped      array default array_construct();
    step         varchar default 'start';
    return_msg   variant default '';
    ident_rx     varchar default '^[A-Za-z_][A-Za-z0-9_]*$';
    bad_name     exception (-20001, 'Invalid Schema Name: letters, digits and underscores only. Must start with a letter or underscore.');
    db_not_found exception (-20002, 'Database does not exist. Please create it first.');

begin

    -- Variables
    db := upper(trim(DB_NAME));
    sch := upper(trim(SCHEMA_NAME));
    fq_sch := db || '.' || sch;
    ro_role  := db || '.' || db || '_' || sch || '_RO';
    rw_role  := db || '.' || db || '_' || sch || '_RW';
    gov_role := db || '.' || db || '_' || sch || '_GOV';

    -- Check Schema name
    step := 'Validate name ' || sch;
    if (not regexp_like(sch, ident_rx)) then
        raise bad_name;
    end if;

    -- Check if database exists
    step := 'Check if database exists ' || db;
    execute immediate
        'show databases like ''' || db || '''
            ->> select count(*) > 0 from $1';
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
            ->> select count(*) > 0 from $1';
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
        'view', 'materialized view',
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

    --------------------------------------------------------------------
    -- Governance : usage on db + schema, create policy/tag objects.
    --------------------------------------------------------------------
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
                       'roles',          array_construct(ro_role, rw_role, gov_role),
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

--drop procedure UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(varchar, varchar, varchar, varchar, boolean);
create or replace procedure UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(
    DB_NAME     varchar,
    SCHEMA_NAME varchar,
    ROLE_NAME   varchar,
    ACCESS_TYPE varchar,
    CREATE_ROLE boolean
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
    create_flag    boolean;
    exists_flag    boolean default true;
    step           varchar default 'start';
    return_msg     variant default '';
    ident_rx       varchar default '^[A-Za-z_][A-Za-z0-9_]*$';
    bad_name       exception (-20001, 'Invalid Role Name: letters, digits and underscores only. Must start with a letter or underscore.');
    bad_access     exception (-20002, 'ACCESS_TYPE must be RO, RW or GOV.');
    db_not_found   exception (-20003, 'Database does not exist. Please create it first.');
    sch_not_found  exception (-20004, 'Schema does not exist. Please create it first.');
    role_not_found exception (-20005, 'Role does not exist. Please create it first.');
    
begin
    db := upper(trim(coalesce(DB_NAME, '')));
    sch := upper(trim(coalesce(SCHEMA_NAME, '')));
    acct_role := upper(trim(coalesce(ROLE_NAME, '')));
    access_lvl := upper(trim(coalesce(ACCESS_TYPE, '')));
    sch_role := db || '.' || db || '_' || sch || '_' || access_lvl;
    create_flag := coalesce(CREATE_ROLE, false);

    --Check Role name
    step := 'Validate name ' || acct_role;
    if (not regexp_like(acct_role, ident_rx)) then
        raise bad_name;
    end if;

    --Access type check
    step := 'Validate access type';
    if (access_lvl not in ('RO', 'RW', 'GOV')) then
        raise bad_access;
    end if;

    -- Check if database exists
    step := 'Check if database exists ' || db;
    execute immediate
        'show databases like ''' || db || '''
            ->> select count(*) > 0 from $1';
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
            ->> select count(*) > 0 from $1';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    if (not exists_flag) then
        raise sch_not_found;
    end if;
    
    --Check if role exists
    step := 'Check if role exists ' || acct_role;
    execute immediate
        'show roles like ''' || acct_role || '''
            ->> select count(*) > 0 from $1';
    select $1
    into :exists_flag
    from table(result_scan(last_query_id()));

    --If create is false but role doesn't exist, fail
    if (not create_flag and not exists_flag) then
        raise role_not_found;
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

    -- RW also gets the shared task / alert / notify capability roles
    if (access_lvl = 'RW') then
        step := 'Grant role ' || acct_role || ' to other roles (RW only)';
        execute immediate 'grant role TASKADMIN  to role ' || acct_role;
        execute immediate 'grant role ALERTADMIN to role ' || acct_role;
        execute immediate 'grant role NOTIFYADMIN to role ' || acct_role;
    end if;

    -- GOV also gets the account-level data governance role
    if (access_lvl = 'GOV') then
        step := 'Grant role ' || acct_role || ' to other roles (GOV only)';
        execute immediate 'grant role DATAGOVADMIN to role ' || acct_role;
    end if;

    --------------------------------------------------------------------
    -- Completed
    --------------------------------------------------------------------
    
    return_msg := iff(exists_flag,
                   'Role ' || acct_role || ' already existed - skipped creation.',
                   'Role ' || acct_role || ' created.')
                  || ' Granted ' || sch_role || ' to ' || acct_role
                  || case access_lvl
                         when 'RW'  then ' (+ TASKADMIN, ALERTADMIN, NOTIFYADMIN).'
                         when 'GOV' then ' (+ DATAGOVADMIN).'
                         else '.'
                     end;

    return object_construct(
        'status',  'SUCCESS',
        'message', :return_msg,
        'details', object_construct(
                       'database_name', :db,
                       'schema_name',   :sch,
                       'role_name',     :acct_role
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

grant usage on procedure UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS(varchar, varchar, varchar, varchar, boolean) to role SYSADMIN;
use role SYSADMIN;