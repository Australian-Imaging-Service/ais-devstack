#!/usr/bin/env bash
set -euo pipefail

XNAT_NAMESPACE="${XNAT_NAMESPACE:-ais-xnat}"
POSTGRES_POD="${POSTGRES_POD:-xnat-web-postgresql-0}"
DB_USER="${DB_USER:-xnat}"
DB_NAME="${DB_NAME:-xnat}"
KUBECTL_CMD="${KUBECTL_CMD:-sudo kubectl}"
LAUNCH_TIMEZONE="${XNAT_WORKFLOW_TIMEZONE:-Australia/Brisbane}"

OLDER_THAN_DAYS=30
EXECUTE=0
SKIP_VACUUM=0
STATUSES=("Complete")
PIPELINES=()

usage() {
  cat <<'EOF'
Usage:
  scripts/purge-xnat-workflows.sh [options]

Options:
  --older-than-days N   Purge workflows older than N days. Default: 30.
  --status STATUS       Match a workflow status. Repeatable. Default: Complete.
  --all-statuses        Remove the default status filter.
  --pipeline NAME       Match a pipeline name exactly. Repeatable. Default: all.
  --execute             Actually delete rows. Without this, only prints a dry-run.
  --skip-vacuum         Do not run VACUUM ANALYZE after an executed purge.
  -h, --help            Show this help.

Environment:
  XNAT_NAMESPACE        Kubernetes namespace. Default: ais-xnat.
  POSTGRES_POD          PostgreSQL pod. Default: xnat-web-postgresql-0.
  DB_USER               PostgreSQL user. Default: xnat.
  DB_NAME               PostgreSQL database. Default: xnat.
  KUBECTL_CMD           kubectl command, supports "sudo kubectl". Default: sudo kubectl.
  XNAT_WORKFLOW_TIMEZONE Time zone used for XNAT launch_time comparisons.
                         Default: Australia/Brisbane.

Examples:
  # Dry-run old completed workflows.
  scripts/purge-xnat-workflows.sh --older-than-days 30

  # Dry-run high-volume completed audit rows older than 1 day.
  scripts/purge-xnat-workflows.sh --older-than-days 1 \
    --pipeline "Uploaded File" \
    --pipeline "Catalog(s) Refreshed"

  # Execute a reviewed dry-run.
  scripts/purge-xnat-workflows.sh --older-than-days 30 --execute
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_bin() {
  local bin="$1"
  command -v "${bin}" >/dev/null 2>&1 || die "missing dependency: ${bin}"
}

kubectl_cmd() {
  # KUBECTL_CMD intentionally supports the repo convention of "sudo kubectl".
  # shellcheck disable=SC2086
  ${KUBECTL_CMD} "$@"
}

join_csv() {
  local IFS=,
  printf '%s' "$*"
}

while (($#)); do
  case "$1" in
    --older-than-days)
      [[ $# -ge 2 ]] || die "--older-than-days requires a value"
      OLDER_THAN_DAYS="$2"
      shift 2
      ;;
    --status)
      [[ $# -ge 2 ]] || die "--status requires a value"
      if [[ "${STATUSES[*]}" == "Complete" ]]; then
        STATUSES=()
      fi
      STATUSES+=("$2")
      shift 2
      ;;
    --all-statuses)
      STATUSES=()
      shift
      ;;
    --pipeline)
      [[ $# -ge 2 ]] || die "--pipeline requires a value"
      PIPELINES+=("$2")
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --skip-vacuum)
      SKIP_VACUUM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "${OLDER_THAN_DAYS}" =~ ^[0-9]+$ ]] || die "--older-than-days must be a non-negative integer"

require_bin kubectl
if [[ "${KUBECTL_CMD}" == sudo* ]]; then
  require_bin sudo
fi

STATUSES_CSV="$(join_csv "${STATUSES[@]}")"
PIPELINES_CSV="$(join_csv "${PIPELINES[@]}")"

sql_file="$(mktemp)"
trap 'rm -f "${sql_file}"' EXIT

if ((EXECUTE)); then
  cat >"${sql_file}" <<'SQL'
\pset pager off
\echo Workflow purge execute
select
  :'older_than_days'::int as older_than_days,
  :'launch_timezone' as launch_timezone,
  now() at time zone :'launch_timezone' as xnat_now,
  (now() at time zone :'launch_timezone') - (:'older_than_days' || ' days')::interval as cutoff,
  nullif(:'statuses', '') as status_filter,
  nullif(:'pipelines', '') as pipeline_filter;

begin;

create temp table workflow_purge_candidates on commit drop as
select
  wrk_workflowdata_id,
  workflowdata_info,
  pipeline_name,
  status,
  launch_time
from wrk_workflowdata
where launch_time < (now() at time zone :'launch_timezone') - (:'older_than_days' || ' days')::interval
  and (:'statuses' = '' or status = any(string_to_array(:'statuses', ',')))
  and (:'pipelines' = '' or pipeline_name = any(string_to_array(:'pipelines', ',')));

select count(*) as candidate_workflow_rows from workflow_purge_candidates;
select pipeline_name, status, count(*)
from workflow_purge_candidates
group by pipeline_name, status
order by count(*) desc, pipeline_name, status
limit 30;

create temp table workflow_purge_meta_candidates on commit drop as
select workflowdata_info
from workflow_purge_candidates
where workflowdata_info is not null;

delete from wrk_workflowdata w
using workflow_purge_candidates c
where w.wrk_workflowdata_id = c.wrk_workflowdata_id;

delete from wrk_workflowdata_meta_data m
using workflow_purge_meta_candidates c
where m.meta_data_id = c.workflowdata_info
  and not exists (
    select 1
    from wrk_workflowdata w
    where w.workflowdata_info = m.meta_data_id
  );

commit;
SQL

  if ((SKIP_VACUUM == 0)); then
    cat >>"${sql_file}" <<'SQL'
vacuum (analyze) wrk_workflowdata;
vacuum (analyze) wrk_workflowdata_meta_data;
SQL
  fi
else
  cat >"${sql_file}" <<'SQL'
\pset pager off
\echo Workflow purge dry-run
select
  :'older_than_days'::int as older_than_days,
  :'launch_timezone' as launch_timezone,
  now() at time zone :'launch_timezone' as xnat_now,
  (now() at time zone :'launch_timezone') - (:'older_than_days' || ' days')::interval as cutoff,
  nullif(:'statuses', '') as status_filter,
  nullif(:'pipelines', '') as pipeline_filter;

begin;

create temp table workflow_purge_candidates on commit drop as
select
  wrk_workflowdata_id,
  workflowdata_info,
  pipeline_name,
  status,
  launch_time
from wrk_workflowdata
where launch_time < (now() at time zone :'launch_timezone') - (:'older_than_days' || ' days')::interval
  and (:'statuses' = '' or status = any(string_to_array(:'statuses', ',')))
  and (:'pipelines' = '' or pipeline_name = any(string_to_array(:'pipelines', ',')));

select count(*) as candidate_workflow_rows from workflow_purge_candidates;
select pipeline_name, status, count(*)
from workflow_purge_candidates
group by pipeline_name, status
order by count(*) desc, pipeline_name, status
limit 30;
select date_trunc('day', launch_time)::date as day, count(*)
from workflow_purge_candidates
group by 1
order by 1 desc
limit 30;

rollback;
SQL
fi

kubectl_cmd -n "${XNAT_NAMESPACE}" exec -i "${POSTGRES_POD}" -- sh -lc '
  export PGPASSWORD="${POSTGRESQL_PASSWORD:-${POSTGRES_PASSWORD:-}}"
  if [ -z "${PGPASSWORD}" ]; then
    echo "POSTGRESQL_PASSWORD/POSTGRES_PASSWORD is not set in the PostgreSQL pod" >&2
    exit 1
  fi
  exec /opt/bitnami/postgresql/bin/psql \
    -U "$1" \
    -d "$2" \
    -v ON_ERROR_STOP=1 \
    -v older_than_days="$3" \
    -v statuses="$4" \
    -v pipelines="$5" \
    -v launch_timezone="$6"
' sh "${DB_USER}" "${DB_NAME}" "${OLDER_THAN_DAYS}" "${STATUSES_CSV}" "${PIPELINES_CSV}" "${LAUNCH_TIMEZONE}" <"${sql_file}"
