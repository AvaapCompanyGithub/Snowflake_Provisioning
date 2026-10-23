--------------------------------------------------
--TASKS

use role SECURITYADMIN;

create role if not exists TASKADMIN
    comment = 'Carries account-level task execution privileges for grant to functional roles';

grant role TASKADMIN to role SYSADMIN;

grant usage on database UTIL_DB to role TASKADMIN;
grant usage, create task on schema UTIL_DB.TASKS to role TASKADMIN;
grant operate, monitor on all tasks in schema UTIL_DB.TASKS to role TASKADMIN;
grant operate, monitor on future tasks in schema UTIL_DB.TASKS to role TASKADMIN;

use role ACCOUNTADMIN;

grant execute task on account to role TASKADMIN;
grant execute managed task on account to role TASKADMIN;

--------------------------------------------------
--ALERTS

use role SECURITYADMIN;

create role if not exists ALERTADMIN
    comment = 'Carries account-level alert execution privileges for grant to functional roles';

grant role ALERTADMIN to role SYSADMIN;

grant usage on database UTIL_DB to role ALERTADMIN;
grant usage, create alert on schema UTIL_DB.ALERTS to role ALERTADMIN;
grant operate, monitor on all alerts in schema UTIL_DB.ALERTS to role ALERTADMIN;
grant operate, monitor on future alerts in schema UTIL_DB.ALERTS to role ALERTADMIN;

use role ACCOUNTADMIN;

grant execute alert on account to role ALERTADMIN;
grant execute managed alert on account to role ALERTADMIN;

--------------------------------------------------
--Email

use role ACCOUNTADMIN;

create or replace notification integration EMAIL_INT
type = email
enabled = true
allowed_recipients =('some_email@acme.corp');

grant usage on integration EMAIL_INT to role SYSADMIN;

use role SECURITYADMIN;

create role if not exists NOTIFYADMIN
    comment = 'Carries account-level notification privileges for grant to functional roles';

grant role NOTIFYADMIN to role SYSADMIN;
grant usage on integration EMAIL_INT to role NOTIFYADMIN;

--------------------------------------------------
--Data Governance

create role if not exists DATAGOVADMIN
    comment = 'Carries account-level data governance privileges for grant to functional roles';

grant role DATAGOVADMIN to role SYSADMIN;

use role ACCOUNTADMIN;

grant apply tag on account to role DATAGOVADMIN;
grant apply masking policy on account to role DATAGOVADMIN;
grant apply row access policy on account to role DATAGOVADMIN;

