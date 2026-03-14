#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUOYI_DIR="${ROOT}/ruoyi"
SQL_DIR="${ROOT}/sql/schema"
OUT_DIR="${ROOT}/out/generated"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PWD="${MYSQL_PWD:-root}"
CODEGEN_BASE_PACKAGE="${CODEGEN_BASE_PACKAGE:-cn.iocoder.yudao}"

cleanup() {
  rm -f "${MYCNF:-}"
}
trap cleanup EXIT

MYCNF="${ROOT}/.tmp.my.cnf"
cat > "${MYCNF}" <<EOF
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PWD}
default-character-set=utf8mb4
EOF
chmod 600 "${MYCNF}"

mysql_base=(mysql --defaults-file="${MYCNF}")

find_bootstrap_sql() {
  local candidates=(
    "${RUOYI_DIR}/sql/mysql/ruoyi-vue-pro.sql"
    "${RUOYI_DIR}/sql/mysql/ruoyi-vue-pro-with-demo.sql"
    "${RUOYI_DIR}/sql/mysql/ruoyi-vue-pro-no-demo.sql"
  )

  local f=""
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
  done

  f="$(find "${RUOYI_DIR}/sql" -type f \( -name 'ruoyi-vue-pro.sql' -o -name 'ruoyi-vue-pro-with-demo.sql' -o -name 'ruoyi-vue-pro-no-demo.sql' \) | head -n 1 || true)"
  if [[ -n "${f}" ]]; then
    echo "${f}"
    return 0
  fi

  return 1
}

cd "${RUOYI_DIR}"

ENGINE_FILE="$(git ls-files | grep -E '/CodegenEngine\.java$' | head -n 1 || true)"
if [[ -z "${ENGINE_FILE}" ]]; then
  echo "ERROR: CodegenEngine.java not found in ruoyi repo"
  exit 10
fi

MODULE_DIR="${ENGINE_FILE%%/src/main/java/*}"
ENGINE_PKG="$(grep -E '^package ' "${ENGINE_FILE}" | head -n 1 | sed -E 's/package ([^;]+);/\1/')"
ENGINE_CLASS="${ENGINE_PKG}.CodegenEngine"

if [[ -z "${MODULE_DIR}" || -z "${ENGINE_PKG}" ]]; then
  echo "ERROR: cannot parse module/package from ${ENGINE_FILE}"
  exit 11
fi

BOOTSTRAP_SQL="$(find_bootstrap_sql || true)"
if [[ -z "${BOOTSTRAP_SQL}" ]]; then
  echo "ERROR: cannot find ruoyi bootstrap sql under ${RUOYI_DIR}/sql"
  exit 12
fi

echo "ENGINE_FILE=${ENGINE_FILE}"
echo "MODULE_DIR=${MODULE_DIR}"
echo "ENGINE_CLASS=${ENGINE_CLASS}"
echo "BOOTSTRAP_SQL=${BOOTSTRAP_SQL}"

TEST_DIR="${RUOYI_DIR}/${MODULE_DIR}/src/test/java/ci/codegen"
mkdir -p "${TEST_DIR}"
cp -f "${ROOT}/tools/codegen/CiCodegenTest.java" "${TEST_DIR}/CiCodegenTest.java"

mkdir -p "${OUT_DIR}"

shopt -s nullglob
sql_files=("${SQL_DIR}"/*.sql)
if [[ ${#sql_files[@]} -eq 0 ]]; then
  echo "ERROR: no sql files in ${SQL_DIR}"
  exit 20
fi

"${mysql_base[@]}" -e "SELECT 1" >/dev/null

echo "==> install module and upstream dependencies into local m2"
mvn -B -q -f "${RUOYI_DIR}/pom.xml" \
  -pl "${MODULE_DIR}" \
  -am \
  -DskipTests \
  install

for f in "${sql_files[@]}"; do
  module="$(basename "${f}" .sql)"
  db="codegen_${module}"

  echo "============================================================"
  echo "==> module=${module}, db=${db}, sql=${f}"
  echo "============================================================"

  "${mysql_base[@]}" -e "DROP DATABASE IF EXISTS \`${db}\`;"
  "${mysql_base[@]}" -e "CREATE DATABASE \`${db}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  echo "==> import ruoyi bootstrap sql"
  "${mysql_base[@]}" "${db}" < "${BOOTSTRAP_SQL}"

  echo "==> import business sql"
  "${mysql_base[@]}" "${db}" < "${f}"

  echo "==> verify infra codegen tables exist"
  "${mysql_base[@]}" -D "${db}" -e "
    SELECT COUNT(*) AS cnt
    FROM information_schema.tables
    WHERE table_schema = '${db}'
      AND table_name IN ('infra_codegen_table', 'infra_codegen_column');
  " | tail -n 1 | {
    read -r cnt
    if [[ "${cnt}" != "2" ]]; then
      echo "ERROR: infra_codegen_table / infra_codegen_column not found in ${db}"
      exit 21
    fi
  }

  echo "==> candidate business tables"
  "${mysql_base[@]}" -D "${db}" -e "
    SELECT table_name, table_comment
    FROM information_schema.tables
    WHERE table_schema = '${db}'
      AND table_type = 'BASE TABLE'
      AND table_name LIKE '${module}\_%'
    ORDER BY table_name;
  " || true

  echo "==> preview codegen metadata counts"
  "${mysql_base[@]}" -D "${db}" -e "
    SELECT 'infra_codegen_table' AS table_name, COUNT(*) AS cnt FROM infra_codegen_table
    UNION ALL
    SELECT 'infra_codegen_column' AS table_name, COUNT(*) AS cnt FROM infra_codegen_column;
  " || true

  echo "==> preview module-related codegen rows"
  "${mysql_base[@]}" -D "${db}" -e "
    SELECT id, table_name, table_comment, class_name, class_comment, module_name, business_name
    FROM infra_codegen_table
    WHERE table_name LIKE '${module}\_%'
       OR module_name = '${module}'
       OR business_name LIKE '${module}\_%'
    ORDER BY id;
  " || true

  export DB_URL="jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${db}?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true"
  export DB_USER="${MYSQL_USER}"
  export DB_PWD="${MYSQL_PWD}"
  export CODEGEN_MODULE_NAME="${module}"
  export CODEGEN_TABLE_PREFIX="${module}_"
  export CODEGEN_ENGINE_CLASS="${ENGINE_CLASS}"
  export CODEGEN_OUTPUT_DIR="${OUT_DIR}/${module}"
  export CODEGEN_BASE_PACKAGE="${CODEGEN_BASE_PACKAGE}"

  rm -rf "${CODEGEN_OUTPUT_DIR}"
  mkdir -p "${CODEGEN_OUTPUT_DIR}"

  echo "==> run codegen test"
  mvn -B -q -f "${RUOYI_DIR}/pom.xml" \
    -pl "${MODULE_DIR}" \
    -Dtest=ci.codegen.CiCodegenTest \
    -Dsurefire.failIfNoSpecifiedTests=false \
    test

  echo "==> scan unreplaced template variables"
  if grep -R '\${' -n "${CODEGEN_OUTPUT_DIR}"; then
    echo "WARNING: found unreplaced template variables under ${CODEGEN_OUTPUT_DIR}"
  else
    echo "OK: no unreplaced template variables under ${CODEGEN_OUTPUT_DIR}"
  fi
done

echo "Generated under ${OUT_DIR}"
