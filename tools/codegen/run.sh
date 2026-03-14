#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUOYI_DIR="${ROOT_DIR}/ruoyi"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PWD="${MYSQL_PWD:-root}"

CODEGEN_DB_NAME="${CODEGEN_DB_NAME:-ruoyi-vue-pro}"
CODEGEN_MODULE_NAME="${CODEGEN_MODULE_NAME:-talent}"
CODEGEN_TABLE_PREFIX="${CODEGEN_TABLE_PREFIX:-${CODEGEN_MODULE_NAME}_}"
CODEGEN_BASE_PACKAGE="${CODEGEN_BASE_PACKAGE:-cn.iocoder.yudao}"
CODEGEN_OUTPUT_DIR="${CODEGEN_OUTPUT_DIR:-${ROOT_DIR}/out/generated}"

DB_URL="${DB_URL:-jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${CODEGEN_DB_NAME}?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true&rewriteBatchedStatements=true&nullCatalogMeansCurrent=true}"
DB_USER="${DB_USER:-${MYSQL_USER}}"
DB_PWD="${DB_PWD:-${MYSQL_PWD}}"

export DB_URL DB_USER DB_PWD
export CODEGEN_OUTPUT_DIR CODEGEN_MODULE_NAME CODEGEN_TABLE_PREFIX CODEGEN_BASE_PACKAGE

mysql_exec() {
  MYSQL_PWD="${MYSQL_PWD}" mysql \
    -h"${MYSQL_HOST}" \
    -P"${MYSQL_PORT}" \
    -u"${MYSQL_USER}" \
    --default-character-set=utf8mb4 \
    "$@"
}

echo "== prepare output dir =="
rm -rf "${CODEGEN_OUTPUT_DIR}"
mkdir -p "${CODEGEN_OUTPUT_DIR}"

echo "== recreate database ${CODEGEN_DB_NAME} =="
mysql_exec -e "DROP DATABASE IF EXISTS \`${CODEGEN_DB_NAME}\`;"
mysql_exec -e "CREATE DATABASE \`${CODEGEN_DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

echo "== import ruoyi base sql =="
BASE_SQL="${RUOYI_DIR}/sql/mysql/ruoyi-vue-pro.sql"
if [[ ! -f "${BASE_SQL}" ]]; then
  echo "ERROR: missing base sql: ${BASE_SQL}"
  exit 1
fi
mysql_exec "${CODEGEN_DB_NAME}" < "${BASE_SQL}"

echo "== import business sql from this repo =="
SQL_ROOT="${ROOT_DIR}/sql/schema"
if [[ ! -d "${SQL_ROOT}" ]]; then
  echo "ERROR: missing business sql dir: ${SQL_ROOT}"
  exit 1
fi

mapfile -t SQL_FILES < <(find "${SQL_ROOT}" -type f -name '*.sql' | sort)

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no sql files found under ${SQL_ROOT}"
  exit 1
fi

for f in "${SQL_FILES[@]}"; do
  echo "import -> ${f}"
  mysql_exec "${CODEGEN_DB_NAME}" < "${f}"
done

echo "== install integration test into ruoyi =="
mkdir -p "${RUOYI_DIR}/yudao-server/src/test/java/ci/codegen"
mkdir -p "${RUOYI_DIR}/yudao-server/src/test/resources"

cp "${ROOT_DIR}/tools/codegen/CiCodegenIT.java" \
   "${RUOYI_DIR}/yudao-server/src/test/java/ci/codegen/CiCodegenIT.java"

cp "${ROOT_DIR}/tools/codegen/application-ci-codegen.yaml" \
   "${RUOYI_DIR}/yudao-server/src/test/resources/application-ci-codegen.yaml"

echo "== verify copied files =="
ls -l "${RUOYI_DIR}/yudao-server/src/test/java/ci/codegen/CiCodegenIT.java"
ls -l "${RUOYI_DIR}/yudao-server/src/test/resources/application-ci-codegen.yaml"

echo "== run codegen integration test =="
cd "${RUOYI_DIR}"
mvn -pl yudao-server -am -Dtest=ci.codegen.CiCodegenIT test

echo "== generated files =="
find "${CODEGEN_OUTPUT_DIR}" -type f | sort || true
