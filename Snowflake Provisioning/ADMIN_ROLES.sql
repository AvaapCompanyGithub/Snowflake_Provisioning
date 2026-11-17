--------------------------------------------------
--ROLE NAMES - change these per customer
--Run this block first in every session (session variables don't persist).
--Keep config.json "admin_roles" in sync with these names.

set TASK_ROLE   = 'TASK_ADMIN';
set ALERT_ROLE  = 'ALERT_ADMIN';
set NOTIFY_ROLE = 'NOTIFY_ADMIN';
set GOV_ROLE    = 'DATAGOV_ADMIN';
set AI_ROLE     = 'AI_USER';

--Email notification recipients - comma-separated, e.g. 'a@acme.corp, b@acme.corp'
--Each address must belong to a user in this account and be verified by that user (Snowsight > profile)
set EMAIL_INT_NAME   = 'EMAIL_INT';
set EMAIL_RECIPIENTS = 'lydia.mancini@avaap.com';

--------------------------------------------------
--TASKS

use role SECURITYADMIN;

create role if not exists identifier($TASK_ROLE)
    comment = 'Carries account-level task execution privileges for grant to functional roles';

grant role identifier($TASK_ROLE) to role SYSADMIN;

grant usage on database UTIL_DB to role identifier($TASK_ROLE);
grant usage, create task on schema UTIL_DB.TASKS to role identifier($TASK_ROLE);
grant operate, monitor on all tasks in schema UTIL_DB.TASKS to role identifier($TASK_ROLE);
grant operate, monitor on future tasks in schema UTIL_DB.TASKS to role identifier($TASK_ROLE);

use role ACCOUNTADMIN;

grant execute task on account to role identifier($TASK_ROLE);
grant execute managed task on account to role identifier($TASK_ROLE);

--------------------------------------------------
--ALERTS

use role SECURITYADMIN;

create role if not exists identifier($ALERT_ROLE)
    comment = 'Carries account-level alert execution privileges for grant to functional roles';

grant role identifier($ALERT_ROLE) to role SYSADMIN;

grant usage on database UTIL_DB to role identifier($ALERT_ROLE);
grant usage, create alert on schema UTIL_DB.ALERTS to role identifier($ALERT_ROLE);
grant operate, monitor on all alerts in schema UTIL_DB.ALERTS to role identifier($ALERT_ROLE);
grant operate, monitor on future alerts in schema UTIL_DB.ALERTS to role identifier($ALERT_ROLE);

use role ACCOUNTADMIN;

grant execute alert on account to role identifier($ALERT_ROLE);
grant execute managed alert on account to role identifier($ALERT_ROLE);

--------------------------------------------------
--Email

use role ACCOUNTADMIN;

--DDL properties can't take session variables, and SET only accepts constants,
--so build the statement in a scripting block. Returns the statement it ran.
execute immediate $$
declare
    int_name   varchar;
    recips     varchar;
    recip_list varchar;
    stmt1      varchar;
    stmt2      varchar;
begin
    select $EMAIL_INT_NAME, $EMAIL_RECIPIENTS into :int_name, :recips;

    -- 1. Create disabled, no recipient list (ENABLED is required for TYPE = EMAIL)
    stmt1 := 'create notification integration if not exists ' || int_name
             || ' type = email enabled = true';
    --execute immediate stmt1;

    -- 2. Merge existing ALLOWED_RECIPIENTS with new ones, dedupe
    execute immediate 'describe integration ' || int_name;

    select listagg(distinct '''' || lower(trim(t.value)) || '''', ', ')
      into :recip_list
      from (select translate("property_value", '[]" ', '') as v
              from table(result_scan(last_query_id()))
             where "property" = 'ALLOWED_RECIPIENTS') d,
           lateral split_to_table(d.v || ',' || replace(:recips, ' ', ''), ',') t
     where trim(t.value) <> '';

    stmt2 := 'alter notification integration ' || int_name
             || ' set allowed_recipients = (' || recip_list || ') enabled = true';
    --execute immediate stmt2;

    return stmt1 || ';\n' || stmt2;
end;
$$;

grant usage on integration EMAIL_INT to role SYSADMIN;

use role SECURITYADMIN;

create role if not exists identifier($NOTIFY_ROLE)
    comment = 'Carries account-level notification privileges for grant to functional roles';

grant role identifier($NOTIFY_ROLE) to role SYSADMIN;
grant usage on integration EMAIL_INT to role identifier($NOTIFY_ROLE);

--------------------------------------------------
--Data Governance

use role SECURITYADMIN;

create role if not exists identifier($GOV_ROLE)
    comment = 'Carries account-level data governance privileges for grant to functional roles';

grant role identifier($GOV_ROLE) to role SYSADMIN;

use role ACCOUNTADMIN;

grant apply tag on account to role identifier($GOV_ROLE);
grant apply masking policy on account to role identifier($GOV_ROLE);
grant apply row access policy on account to role identifier($GOV_ROLE);

use role ACCOUNTADMIN;

--Intelligence Object - Once per account
create SNOWFLAKE INTELLIGENCE if not exists SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

--SYSADMIN only
-- Change the CoWork object: add or remove agents and change its settings
grant modify on SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT to role SYSADMIN;
-- View AI Gateway activity and usage
grant monitor on AI GATEWAY SNOWFLAKE to role SYSADMIN;

--------------------------------------------------
-- AI

--Defaults
use role ACCOUNTADMIN;

--Intelligence Object - Once per account
create SNOWFLAKE INTELLIGENCE if not exists SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

--SYSADMIN only
--Change the CoWork object: add or remove agents and change its settings
grant modify on SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT to role SYSADMIN;
--View AI Gateway activity and usage
grant monitor on AI GATEWAY SNOWFLAKE to role SYSADMIN;

--New Role

use role SECURITYADMIN;

create role if not exists identifier($AI_ROLE)
    comment = 'Carries account-level AI privileges (Cortex, AI functions, Snowflake Intelligence) for grant to functional roles';

grant role identifier($AI_ROLE) to role SYSADMIN;

--Grant AI perms to the new role and SYSADMIN

use role ACCOUNTADMIN;

declare
    roles array default array_construct('SYSADMIN', $AI_ROLE);
    r string;

begin
    for i in 0 to array_size(roles) - 1 do
        r := roles[i]::string;

        --Cortex AI features: CoCo, Cortex Agents, Cortex Search, AI functions
        execute immediate 'grant database role SNOWFLAKE.CORTEX_USER to role ' || r;
        -- Account-level permission to call AI functions (AI_COMPLETE, AI_CLASSIFY, etc.)
        execute immediate 'grant use AI FUNCTIONS on account to role ' || r;
        --All current and future LLMs (model access is controlled only by model RBAC)
        execute immediate 'grant application role SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" to role ' || r;
        -- Route AI requests through Snowflake's AI Gateway (system grant shown as AI_GATEWAY / SNOWFLAKE)
        execute immediate 'grant usage on AI GATEWAY SNOWFLAKE to role ' || r;
        --Create and run scheduled, unattended agent automations (CoWork/CoCo Automations)
        execute immediate 'grant EXECUTE AGENT TASK on account to role ' || r;
        --See and use agents in CoWork
        execute immediate 'grant usage on SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT to role ' || r;
    end for;
end;

show grants to role identifier($AI_ROLE);