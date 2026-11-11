# Snowflake Provisioning

A Streamlit in Snowflake app that creates databases, schemas and roles, and grants access to them in a consistent way.

The app runs three steps:

1. **Database:** create a database, or update its retention on an existing one, owned by SYSADMIN.
2. **Schema:** create a managed-access schema and one database role per access type.
3. **Role:** grant one of those database roles to an account role. This can also grant a warehouse and any matching admin roles.

The app calls stored procedures that do the actual work. You can also call them directly from SQL.

## Files

All files are in `Snowflake Provisioning/`.

| File | Purpose |
|---|---|
| `snowflake_provisioning.py` | The Streamlit app |
| `config.json` | Access types, admin role mapping and UI options |
| `PROVISIONING.sql` | Creates the stored procedures `SP_PROVISION_DB`, `SP_PROVISION_SCHEMA` and `SP_GRANT_DBSCH_ACCESS` |
| `ADMIN_ROLES.sql` | One-time setup of the account-level admin roles, the email integration and AI access |
| `snowflake.yml` | Deployment settings for `snow streamlit deploy` |
| `pyproject.toml`, `.streamlit/config.toml` | Python and Streamlit settings |

## Access types

Each provisioned schema gets one database role per access type, named `<DB>_<SCHEMA>_<TYPE>`, for example `SALES_RAW_RO`.

| Type | What it allows |
|---|---|
| **RO** (Read-Only) | Select on tables, views and other readable objects, and use of Streamlit apps. No AI. |
| **RW** (Read-Write) | Everything RO has, plus insert, update, delete and truncate; creating objects; reading and writing stages; running functions and procedures. Also building and using AI objects: agents, Cortex Search services, semantic views and models. |
| **GOV** (Governance) | Create masking policies, row access policies and tags. |
| **AI** | Use of agents, Cortex Analyst (select and references on semantic views) and Cortex Search. **No direct queries on tables or views.** |
| **APP** | View Streamlit apps only. Apps run with their owner's rights, so no access to the underlying data is needed. |

Future grants are used throughout, so objects created later in the schema are covered automatically. If Snowflake rejects a grant for an object type, the procedure skips it and lists it under `skipped_grants` in the result.

### Admin roles (account-level privileges)

Some rights are granted on the whole account rather than a single schema. These come from admin roles that are granted along with the matching access type:

| Admin role | Granted with | Holds |
|---|---|---|
| TASK_ADMIN | RW | Execute tasks and managed tasks |
| ALERT_ADMIN | RW | Execute alerts and managed alerts |
| NOTIFY_ADMIN | RW | Usage on the email notification integration |
| DATAGOV_ADMIN | GOV | Apply tags, masking policies and row access policies |
| AI_USER | AI, RW | Cortex user, AI functions, all Cortex models, usage on Snowflake Intelligence |

These roles carry **account-wide** privileges, so for example anyone given RW on any schema can execute tasks across the account.

## Setup

### Prerequisites

- `UTIL_DB` with these schemas: `ADMIN` (procedures), `STREAMLIT` (app), `TASKS` and `ALERTS`
- The `ADMIN_WH` warehouse and the `SYSTEM_COMPUTE_POOL_CPU` compute pool (both referenced in `snowflake.yml`)
- Streamlit 1.45 or later, which the app needs for its type-in dropdowns

### 1. Admin roles: `ADMIN_ROLES.sql`

Run as ACCOUNTADMIN or SECURITYADMIN. The script switches between them as needed.

1. Set the variables at the top: the role names and the email recipients. Run this block first in every session, because session variables don't persist between sessions.
2. Run the rest of the script.

The AI section also removes Cortex and AI function access from `PUBLIC`, so that only roles given AI access can use them. Run it once per account.

The email recipient list can be at most 256 characters, the limit for a Snowflake session variable. Each address must belong to a user in the account, and that user must have verified it in Snowsight (profile → Email). Otherwise Snowflake rejects it with "Email recipients … are not allowed".

### 2. Procedures: `PROVISIONING.sql`

Run the whole script. The database and schema procedures are owned by SYSADMIN. The grant procedure is owned by SECURITYADMIN, and SYSADMIN is given usage on it.

### 3. Configuration: `config.json`

```json
{
  "access": {
    "Read-Only (RO)": "RO",
    "Read-Write (RW)": "RW",
    "Governance (GOV)": "GOV",
    "AI Read-Only (AI)": "AI",
    "Streamlit Apps - View Only (APP)": "APP"
  },
  "show_create_role": true,
  "show_scim_warning": true,
  "admin_roles": {
    "RW":  ["TASK_ADMIN", "ALERT_ADMIN", "NOTIFY_ADMIN", "AI_USER"],
    "GOV": ["DATAGOV_ADMIN"],
    "AI":  ["AI_USER"]
  }
}
```

- **`access`**: the dropdown label mapped to the access type code. Remove an entry to hide that type.
- **`show_create_role`**: shows the "Create role if it doesn't exist" checkbox. Set it to `false` when all roles come from SCIM.
- **`show_scim_warning`**: shows the red SCIM warning under that checkbox. Set it to `false` for accounts that don't use SCIM. It has no effect when `show_create_role` is `false`.
- **`admin_roles`**: for each access type, the admin roles it also grants. Leave out access types that grant none. **The names must match the variables in `ADMIN_ROLES.sql`.** If a name doesn't match, the app skips that role and reports it under "Skipped admin roles".
- **`access_help`** (optional): replaces the description shown under the access type dropdown, for example `"access_help": {"AI": "Custom text"}`.

### 4. Deploy the app

From the `Snowflake Provisioning/` folder:

```
snow streamlit deploy --replace
```

The app runs as its owner and is shared with SYSADMIN. It is scheduled to start at 8 AM Eastern on weekdays. See `snowflake.yml` for these settings.

## Upgrading existing schemas

Schemas provisioned before the AI and APP types were added don't have those database roles, and they don't have the newer RW grants. **Re-run step 2 (Schema) on each one.** It's safe to re-run: it creates only what is missing and repeats the grants.

Granting AI or APP on a schema that hasn't been upgraded fails with a message asking you to re-run step 2.

Roles that already have RW only get AI_USER after you re-run step 3 (Role) with RW.

## Notes

- **Ownership:** an object belongs to the account role that created it. RW gives other roles usage, modify, operate and monitor on AI objects, but changing the definition of a semantic view or Cortex Search service still needs its owner.
- **Agents using a YAML semantic model on a stage:** AI users would also need read on that stage. Using semantic views avoids this.
- **Warehouses:** AI and RW users need a warehouse to run queries. Pick one in step 3, or grant it separately.
- **Protected roles:** ACCOUNTADMIN, SECURITYADMIN, USERADMIN, SYSADMIN, ORGADMIN, PUBLIC and the configured admin roles can never be the target role in step 3.
