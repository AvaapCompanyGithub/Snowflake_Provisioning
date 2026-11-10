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
    recips varchar;
    stmt   varchar;
begin
    select $EMAIL_RECIPIENTS into :recips;
    stmt := 'create or replace notification integration EMAIL_INT type = email enabled = true allowed_recipients = ('''
            || replace(replace(recips, ' ', ''), ',', ''', ''') || ''')';
    execute immediate stmt;
    return stmt;
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

--------------------------------------------------
--AI

use role ACCOUNTADMIN;

--Once per account
create SNOWFLAKE INTELLIGENCE if not exists SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

--Take AI off for PUBLIC - run once
use role SECURITYADMIN;

revoke database role SNOWFLAKE.CORTEX_USER from role PUBLIC;
revoke database role SNOWFLAKE.COPILOT_USER from role PUBLIC;
revoke USE AI FUNCTIONS on account from role PUBLIC;
revoke application role SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" from role PUBLIC;
call SNOWFLAKE.LOCAL.REVOKE_FROM_PUBLIC_APPLICATION_ROLE('APP_ROLE', 'CORTEX-MODEL-ROLE-ALL');
revoke usage on ai gateway SNOWFLAKE from role PUBLIC;  --system grant shown as AI_GATEWAY / SNOWFLAKE

--Check
show grants to role PUBLIC;                      -- no CORTEX_USER, AI_FUNCTIONS_USER, CORTEX_EMBED_USER, CORTEX_AGENT_USER, USE AI FUNCTION*
show grants to application role SNOWFLAKE.PUBLIC; -- CORTEX-MODEL-ROLE-ALL must be gone

/*
--Restore AI to PUBLIC (undo the revokes above) - every user gets AI again
use role ACCOUNTADMIN;

grant database role SNOWFLAKE.CORTEX_USER to role PUBLIC;
grant database role SNOWFLAKE.COPILOT_USER to role PUBLIC;
grant use ai functions on account to role PUBLIC;
grant application role SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" to role PUBLIC;
grant usage on ai gateway SNOWFLAKE to role PUBLIC;

--The REVOKE_FROM_PUBLIC_APPLICATION_ROLE call above has no documented undo procedure.
--The PUBLIC grant above gives the same model access. If a model is still blocked, check with Snowflake support.

show grants to role PUBLIC;
show grants to application role SNOWFLAKE.PUBLIC;

use role SECURITYADMIN;
*/

--Admin role
create role if not exists identifier($AI_ROLE)
    comment = 'Carries account-level AI privileges (Cortex, AI functions, Snowflake Intelligence) for grant to functional roles';

grant role identifier($AI_ROLE) to role SYSADMIN;

use role ACCOUNTADMIN;

grant database role SNOWFLAKE.CORTEX_USER to role identifier($AI_ROLE);
grant use ai functions on account to role identifier($AI_ROLE);
grant application role SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" to role identifier($AI_ROLE);
grant usage on ai gateway SNOWFLAKE to role identifier($AI_ROLE);  --was revoked from PUBLIC above

grant usage on SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT to role identifier($AI_ROLE);
--MODIFY intentionally not granted: it lets holders add/remove agents in Snowflake Intelligence for the whole account.
--Grant it directly to a specific admin role if needed:
--grant modify on SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT to role <ROLE>;

show grants to role identifier($AI_ROLE);

