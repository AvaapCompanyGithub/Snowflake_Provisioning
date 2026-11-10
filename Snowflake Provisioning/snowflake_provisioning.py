"""
Snowflake Provisioning

Creates databases, schemas, roles and applies permissions to database/schema objects
"""

import streamlit as st
import json
from pathlib import Path
from snowflake.snowpark.context import get_active_session

# -------------------------------------------------
# Session
# -------------------------------------------------

try:
    session = get_active_session()
except Exception:
    session = st.connection("snowflake").session()

# -------------------------------------------------
# Page config
# -------------------------------------------------

st.set_page_config(
    page_title="Snowflake Provisioning",
    page_icon="📊",
    layout="wide",
)

# ------------------------------------------------------------------
# Config from config.json (same folder as this app)
# ------------------------------------------------------------------
def _load_config():
    candidates = []
    try:
        candidates.append(Path(__file__).resolve().parent / "config.json")
    except Exception:
        pass
    candidates.append(Path("config.json"))
    candidates.append(Path.cwd() / "config.json")

    for path in candidates:
        try:
            if path.is_file():
                with open(path, encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    return data, path
        except Exception:
            continue

    # Config is optional — fall back to defaults
    return {}, None

_cfg, _cfg_path = _load_config()

# ----------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------

NAVY = "#16324F"
NAVY_LIGHT = "#2A5F8F"
NAVY_DEEP = "#0F2438"
SNOW_BLUE = "#29B5E8"
BLUE_MID = "#5FC5EC"
BLUE_LIGHT = "#A7D8EF"
BLUE_PALE = "#CFE8F5"
PANEL = "#E9EEF2"
CARD_BG = "#FFFFFF"
INK = "#0F2438"
MUTED = "#6B7F92"
GREEN = "#1F9D6B"
RED = "#C23B3B"
WHITE = "#FFFFFF"
GOLD = "#D4A017"
CHART_BLUE = "#4C6EF5"
CHART_GOLD = "#D4A017"

# ----------------------------------------------------------------------
# Style
# ----------------------------------------------------------------------

st.markdown(
    f"""
    <style>
      .stApp {{ background: #F4F6F8; }}
      .block-container {{ padding-top: 1.4rem; max-width: 1600px; }}
      #MainMenu, footer {{ visibility: hidden; }}

      .masthead {{ display: flex; align-items: baseline; gap: .55rem; margin-bottom: .1rem; }}
      .masthead h1 {{
        font-size: 1.65rem; font-weight: 800; color: {INK};
        margin: 0; letter-spacing: -.02em;
      }}
      .masthead .logo {{
        height: 28px; width: auto; object-fit: contain;
        display: block;
      }}
      .masthead .logo-fallback {{
        width: 28px; height: 28px; border-radius: 6px;
        background: linear-gradient(135deg, {SNOW_BLUE}, {NAVY_LIGHT});
        flex-shrink: 0;
      }}
      .subhead {{ color: {MUTED}; font-size: .75rem; margin: .1rem 0 .8rem 0; }}

      .card {{
        border-radius: 12px; padding: .75rem .9rem 0.85rem .9rem; height: 100%;
        text-align: center; background: #EEF2F6;
        border: 1px solid #E2E8EE;
      }}
      .card.primary {{
        background: {NAVY_LIGHT}; color: #FFFFFF; text-align: left;
        padding: .85rem 1rem; border: none;
      }}
      .card .label {{
        font-size: .62rem; font-weight: 600; letter-spacing: .01em;
        opacity: .85; margin-bottom: .2rem; line-height: 1.2;
        color: {MUTED};
      }}
      .card.primary .label {{ color: rgba(255,255,255,.85); }}
      .card .value {{
        font-size: 1.25rem; font-weight: 800; letter-spacing: -.03em;
        line-height: 1.15; font-variant-numeric: tabular-nums;
        color: {INK};
        word-break: break-word;
      }}
      .card.primary .value {{ color: #FFFFFF; font-size: 1.42rem; }}
      .card .delta-pill {{
        display: inline-block; margin-top: .35rem; margin-bottom: .25rem;
        padding: .12rem .5rem; border-radius: 999px;
        font-size: .62rem; font-weight: 600;
      }}
      .card .delta-pill.up {{ background: #D8F3E7; color: {GREEN}; }}
      .card .delta-pill.down {{ background: #FDE8E8; color: {RED}; }}
      .card .delta-pill.flat {{ background: #E6EBF0; color: {MUTED}; }}
      .card.primary .delta-pill.up {{ background: rgba(125,255,179,.22); color: #7DFFB3; }}
      .card.primary .delta-pill.down {{ background: rgba(255,180,180,.22); color: #FFB4B4; }}
      .card.primary .delta-pill.flat {{ background: rgba(255,255,255,.16); color: rgba(255,255,255,.85); }}
      .card .foot {{
        font-size: .78rem; color: {MUTED}; margin-top: .15rem;
        line-height: 1.35;
      }}
      .card.primary .foot {{ color: rgba(255,255,255,.78); }}

      .section-title {{
        font-size: 1.28rem; font-weight: 800; color: {INK};
        margin: 0.15rem 0 0.75rem 0; letter-spacing: -.02em;
      }}
      .panel-title {{
        font-size: .92rem; font-weight: 700; color: {INK};
        margin: 0 0 .45rem .05rem;
      }}
      .chart-box {{
        background: {WHITE};
        border: 1px solid #E2E8EE;
        border-radius: 12px;
        padding: .7rem .8rem .55rem .8rem;
        height: 100%;
      }}
      .table-box {{
        background: {WHITE};
        border: 1px solid #E2E8EE;
        border-radius: 12px;
        padding: .7rem .8rem .85rem .8rem;
      }}

      .note {{
        text-align: left; color: {MUTED}; font-size: .66rem;
        margin: .55rem 0 1rem 0; line-height: 1.4;
      }}
      div[data-testid="stSelectbox"] label,
      div[data-testid="stDateInput"] label {{
        color: {MUTED}; font-size: .72rem;
      }}

      div[data-testid="stDataFrame"] {{
        font-size: 0.72rem;
      }}
      div[data-testid="stDataFrame"] table {{
        font-size: 0.72rem;
      }}
      div[data-testid="stDataFrame"] th {{
        font-size: 0.68rem !important;
        padding-top: 0.25rem !important;
        padding-bottom: 0.25rem !important;
      }}
      div[data-testid="stDataFrame"] td {{
        font-size: 0.72rem !important;
        padding-top: 0.2rem !important;
        padding-bottom: 0.2rem !important;
      }}
    </style>
    """,
    unsafe_allow_html=True,
)

# ----------------------------------------------------------------------
# Logo
# ----------------------------------------------------------------------

_logo_html = '<div class="logo-fallback" title="Add logo.png or logo.jpg"></div>'
try:
    import base64 as _b64

    _logo_dir = Path(__file__).resolve().parent
    _logo_path = None
    _mime = None
    for _name, _m in (
        ("logo.png", "image/png"),
        ("logo.jpg", "image/jpeg"),
        ("logo.jpeg", "image/jpeg"),
    ):
        _candidate = _logo_dir / _name
        if _candidate.is_file():
            _logo_path, _mime = _candidate, _m
            break
    if _logo_path is not None:
        _b64data = _b64.b64encode(_logo_path.read_bytes()).decode("ascii")
        _logo_html = (
            f'<img class="logo" alt="Logo" '
            f'src="data:{_mime};base64,{_b64data}"/>'
        )
except Exception:
    pass

# -------------------------------------------------
# Metadata lookups (cached; cleared after every successful proc call)
# -------------------------------------------------

#Get values from config.json
ACCESS = _cfg.get("access", {"Read-Only (RO)": "RO"})
SHOW_CREATE_ROLE = bool(_cfg.get("show_create_role", True))
SHOW_SCIM_WARNING = bool(_cfg.get("show_scim_warning", True))

#One-line description per access type code, shown under the Access type dropdown
ACCESS_HELP = {
    "RO":  "Read-only data access: select on tables/views, use Streamlit apps. No AI.",
    "RW":  "Full working access: read/write data, create objects, build and use AI (agents, Cortex Search, semantic views, models).",
    "GOV": "Create masking policies, row access policies and tags.",
    "AI":  "Read-only through AI: use agents, Cortex Analyst and Cortex Search. No direct table/view queries, no building AI objects.",
    "APP": "View Streamlit apps only. No access to the underlying data.",
}
ACCESS_HELP.update({k.upper(): v for k, v in _cfg.get("access_help", {}).items()})

#Admin roles per access type in config.json, e.g. {"RW": ["TASK_ADMIN", "AI_USER"], "AI": ["AI_USER"]}.
#Turned into ROLE -> [ACCESS_TYPE, ...] for SP_GRANT_DBSCH_ACCESS, e.g. {"AI_USER": ["RW", "AI"]}.
ADMIN_ROLES = {}
for _access, _roles in _cfg.get("admin_roles", {}).items():
    for _r in (_roles if isinstance(_roles, list) else [_roles]):
        ADMIN_ROLES.setdefault(_r.upper(), []).append(_access.upper())

#Built-in Snowflake roles - SP_GRANT_DBSCH_ACCESS always rejects these
SYSTEM_ROLES = {"ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "ORGADMIN", "PUBLIC"}

#DB List
@st.cache_data(ttl=300, show_spinner=False)
def list_databases():
    rows = session.sql("SHOW DATABASES").collect()
    return sorted(r["name"] for r in rows if r["kind"] == "STANDARD")

#Schema List
@st.cache_data(ttl=300, show_spinner=False)
def list_schemas(db):
    q = db.replace('"', '""')
    rows = session.sql(f'SHOW SCHEMAS IN DATABASE "{q}"').collect()
    return sorted(r["name"] for r in rows if r["name"] != "INFORMATION_SCHEMA")

#Provisioned schema list - schemas with the _RO/_RW/_GOV database roles from SP_PROVISION_SCHEMA
@st.cache_data(ttl=300, show_spinner=False)
def list_provisioned_schemas(db):
    q = db.replace('"', '""')
    rows = session.sql(f'SHOW DATABASE ROLES IN DATABASE "{q}"').collect()
    db_roles = {r["name"] for r in rows}
    return [s for s in list_schemas(db)
            if all(f"{db}_{s}_{a}" in db_roles for a in ("RO", "RW", "GOV"))]

#Role list
@st.cache_data(ttl=300, show_spinner=False)
def list_roles():
    rows = session.sql("SHOW ROLES").collect()
    hidden = SYSTEM_ROLES | ADMIN_ROLES.keys()
    return sorted(r["name"] for r in rows if r["name"] not in hidden)

#Warehouse list - user-created warehouses owned by SYSADMIN
@st.cache_data(ttl=300, show_spinner=False)
def list_warehouses():
    rows = session.sql("SHOW WAREHOUSES").collect()
    return sorted(r["name"] for r in rows
                  if r["owner"] == "SYSADMIN" and not r["name"].startswith("SYSTEM$"))

# -------------------------------------------------
# Helpers
# -------------------------------------------------

def pick_or_enter(label, options, key):
    """Combobox: pick an existing value or type a new one into the same box.
    Requires Streamlit >= 1.45 (accept_new_options)."""
    try:
        choice = st.selectbox(label, options, index=None, accept_new_options=True,
                              placeholder="Select or type…", key=f"{key}_sel")
    except TypeError:
        st.error(f"This app needs Streamlit 1.45+ for type-in dropdowns "
                 f"(running {st.__version__}). Update the Streamlit package version.")
        st.stop()
    return (choice or "").strip()

def literal(text):
    """Escape Markdown/LaTeX so names like BAD_NAME_##^@&&$% render as typed."""
    for ch in "\\`*_{}[]<>()#+-.!|$~:":
        text = text.replace(ch, "\\" + ch)
    return text.replace("\n", "  \n")  # keep the proc's chr(10) line breaks

def run(proc, *args):
    try:
        with st.spinner("Working…"):
            result = session.call(proc, *args)   # bound args, no SQL string building
    except Exception as e:
        # proc raised, or the call failed before returning (perms on proc, session drop)
        st.error(literal(str(e)))
        return False

    # procs return a VARIANT object; Snowpark may hand it back as a dict or a JSON string
    if isinstance(result, str):
        try:
            payload = json.loads(result)
        except (TypeError, ValueError):
            st.error(literal(f"Unexpected response: {result}"))
            return False
    elif isinstance(result, dict):
        payload = result
    else:
        payload = {}

    #details is an extra key in the JSON returned from the proc
    details = payload.get("details")

    status = payload.get("status")

    if status not in ("SUCCESS", "WARNING"):
        st.error(literal(payload.get("message", "Unknown error.")))
        if details:
            with st.expander("Details"):
                st.json(details)
        return False

    # success, or done with something skipped (WARNING)
    if status == "WARNING":
        st.warning(literal(payload.get("message", "Done, with warnings.")))
    else:
        st.success(literal(payload.get("message", "Done.")))
    if details:
        with st.expander("Details"):
            st.json(details)

    st.cache_data.clear()   # pick up new DBs / schemas / roles
    return True

def prefill(key, value, options):
    """Preselect a downstream widget only if the object now exists.
    Must run before that widget renders this run."""
    if value in options:
        st.session_state[key] = value

# ----------------------------------------------------------------------
# Page Header
# ----------------------------------------------------------------------

st.markdown(
    f'<div class="masthead">{_logo_html}<h1>Snowflake Provisioning</h1></div>'
    '<div class="subhead">Creates databases, schemas, roles and applies permissions to database/schema objects.</div>'
        f'<div style="color:{MUTED};font-size:.72rem;margin:-0.35rem 0 0.15rem 0;">'
        f"Runs as SYSADMIN. Databases and Schema are owned by SYSADMIN.</div>",
    unsafe_allow_html=True,
)

st.divider()

# -------------------------------------------------
# UI
# -------------------------------------------------

# Section 1: Database
st.header("1. Database")
st.caption("Create a new database, or update an existing one, as SYSADMIN.")
db1 = pick_or_enter("Database", list_databases(), "s1_db")
ret = st.number_input("Retention (days)", min_value=1, max_value=90,
                      value=1, step=1, key="s1_ret")
if st.button("Provision database", key="s1_go", disabled=not db1):
    if run("UTIL_DB.ADMIN.SP_PROVISION_DB", db1, int(ret)):
        # unquoted identifiers resolve to uppercase
        prefill("s2_db", db1.upper(), list_databases())

st.divider()

# Section 2: Schema
st.header("2. Schema")
st.caption("Create a new schema in existing database, as SYSADMIN. "
           "Creates all the appropriate permissions. "
           "Re-run on an existing schema to add newer access types (e.g. AI, APP) and refresh its grants.")
db2 = st.selectbox("Database", list_databases(), index=None,
                   placeholder="Select…", key="s2_db")
sch2 = st.text_input("Schema name", key="s2_sch").strip()
if st.button("Provision schema", key="s2_go", disabled=not (db2 and sch2)):
    if run("UTIL_DB.ADMIN.SP_PROVISION_SCHEMA", db2, sch2):
        prefill("s3_db", db2, list_databases())
        prefill(f"s3_sch_{db2}", sch2.upper(), list_provisioned_schemas(db2))

st.divider()

# Section 3: Role
st.header("3. Role")
st.caption("Grant permissions on the database and schema to this role. "
           "Only schemas provisioned in step 2 are listed.")
db3 = st.selectbox("Database", list_databases(), index=None,
                   placeholder="Select…", key="s3_db")
# keying on db3 resets the schema selection whenever the database changes
sch3 = st.selectbox("Schema", list_provisioned_schemas(db3) if db3 else [], index=None,
                    placeholder="Select…", key=f"s3_sch_{db3}", disabled=not db3)
role3 = pick_or_enter("Role", list_roles(), "s3_role")
if SHOW_CREATE_ROLE:
    create3 = st.checkbox("Create role if it doesn't exist", key="s3_create")
    if SHOW_SCIM_WARNING:
        st.caption(":red[If SCIM provisioning is enabled and this role maps to an identity provider group "
                   "(e.g. Entra ID, Okta), provision it through SCIM instead of creating it here.]")
else:
    create3 = False
access3 = st.selectbox("Access type", list(ACCESS), key="s3_access")
if ACCESS_HELP.get(ACCESS[access3].upper()):
    st.caption(ACCESS_HELP[ACCESS[access3].upper()])
# admin roles from config.json that come with this access type (account-level privileges)
extra3 = [r for r, a in ADMIN_ROLES.items() if ACCESS[access3] in a]
if extra3:
    st.caption(f"{access3} also grants {', '.join(extra3)} (account-level privileges).")
wh3 = st.selectbox("Warehouse (optional)", list_warehouses(), index=None,
                   placeholder="None", key="s3_wh")
if st.button("Grant access", key="s3_go", disabled=not (db3 and sch3 and role3)):
    run("UTIL_DB.ADMIN.SP_GRANT_DBSCH_ACCESS",
        db3, sch3, role3, ACCESS[access3], bool(create3),
        wh3, json.dumps(ADMIN_ROLES))
