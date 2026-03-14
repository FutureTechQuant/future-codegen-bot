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
EOF
chmod 600 "${MYCNF}"
mysql_base=(mysql --defaults-file="${MYCNF}")

cd "${RUOYI_DIR}"

ENGINE_FILE="$(git ls-files | grep -E '/CodegenEngine\.java$' | head -n 1 || true)"
if [[ -z "${ENGINE_FILE}" ]]; then
  echo "ERROR: CodegenEngine.java not found in ruoyi repo"
  exit 10
fi

MODULE_DIR="${ENGINE_FILE%%/src/main/java/*}"
ENGINE_PKG="$(grep -E '^package ' "${ENGINE_FILE}" | head -n1 | sed -E 's/package ([^;]+);/\1/')"
ENGINE_CLASS="${ENGINE_PKG}.CodegenEngine"

if [[ -z "${MODULE_DIR}" || -z "${ENGINE_PKG}" ]]; then
  echo "ERROR: cannot parse module/package from ${ENGINE_FILE}"
  exit 11
fi

echo "ENGINE_FILE=${ENGINE_FILE}"
echo "MODULE_DIR=${MODULE_DIR}"
echo "ENGINE_CLASS=${ENGINE_CLASS}"

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
  echo "==> module=${module}, db=${db}, sql=${f}"

  "${mysql_base[@]}" -e "DROP DATABASE IF EXISTS \`${db}\`;"
  "${mysql_base[@]}" -e "CREATE DATABASE \`${db}\` DEFAULT CHARACTER SET utf8mb4;"
  "${mysql_base[@]}" "${db}" < "${f}"

  export DB_URL="jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${db}?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true"
  export DB_USER="${MYSQL_USER}"
  export DB_PWD="${MYSQL_PWD}"
  export CODEGEN_MODULE_NAME="${module}"
  export CODEGEN_ENGINE_CLASS="${ENGINE_CLASS}"
  export CODEGEN_OUTPUT_DIR="${OUT_DIR}/${module}"

  rm -rf "${CODEGEN_OUTPUT_DIR}"
  mkdir -p "${CODEGEN_OUTPUT_DIR}"

  mvn -B -q -f "${RUOYI_DIR}/pom.xml" \
    -pl "${MODULE_DIR}" \
    -Dtest=ci.codegen.CiCodegenTest \
    -Dsurefire.failIfNoSpecifiedTests=false \
    test
done

echo "Generated under ${OUT_DIR}"
