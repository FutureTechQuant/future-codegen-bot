#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/out/generated"
WORK_DIR="${ROOT}/out/publish"

OWNER="${GITHUB_OWNER:-FutureTechQuant}"
BACKEND_REPO="ruoyi-vue-pro"
FRONTEND_REPO="yudao-ui-admin-vue3"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: missing env ${name}"
    exit 1
  fi
}

repo_url() {
  local repo="$1"
  echo "https://x-access-token:${GH_TOKEN}@github.com/${OWNER}/${repo}.git"
}

git config --global user.name "future-codegen-bot"
git config --global user.email "actions@users.noreply.github.com"

require_env GH_TOKEN
mkdir -p "${WORK_DIR}"

clone_target() {
  local repo="$1"
  local dir="$2"

  rm -rf "${dir}"
  git clone "$(repo_url "${repo}")" "${dir}"
}

find_generated_frontend_src_dirs() {
  find "${OUT_DIR}" -type d -path "*/yudao-ui-admin-vue3/src"
}

find_generated_modules() {
  find "${OUT_DIR}" -maxdepth 2 -type d -name "yudao-module-*"
}

ensure_module_pom() {
  local backend_root="$1"
  local module_name="$2"
  local module_dir="${backend_root}/${module_name}"
  local target_pom="${module_dir}/pom.xml"
  local template_pom="${backend_root}/yudao-module-member/pom.xml"

  if [[ -f "${target_pom}" ]]; then
    return
  fi

  if [[ ! -f "${template_pom}" ]]; then
    echo "ERROR: template pom not found: ${template_pom}"
    exit 1
  fi

  cp "${template_pom}" "${target_pom}"
  sed -i "s/yudao-module-member/${module_name}/g" "${target_pom}"
  sed -i "s/member 模块，我们放会员业务。/${module_name#yudao-module-} 模块，自动生成。/g" "${target_pom}"
  sed -i "s/例如说：会员中心等等/例如说：${module_name#yudao-module-} 业务。/g" "${target_pom}"
}

ensure_root_module_declared() {
  local backend_root="$1"
  local module_name="$2"
  local root_pom="${backend_root}/pom.xml"

  grep -q "<module>${module_name}</module>" "${root_pom}" && return

  python3 - <<PY
from pathlib import Path
p = Path(r"${root_pom}")
s = p.read_text(encoding="utf-8")
insert = f"        <module>${module_name}</module>\n"
needle = "</modules>"
if needle in s and insert.strip() not in s:
    s = s.replace(needle, insert + "    </modules>", 1)
p.write_text(s, encoding="utf-8")
PY
}

ensure_server_dependency() {
  local backend_root="$1"
  local module_name="$2"
  local server_pom="${backend_root}/yudao-server/pom.xml"

  grep -q "<artifactId>${module_name}</artifactId>" "${server_pom}" && return

  python3 - <<PY
from pathlib import Path
p = Path(r"${server_pom}")
s = p.read_text(encoding="utf-8")
block = f"""
        <dependency>
            <groupId>cn.iocoder.boot</groupId>
            <artifactId>${module_name}</artifactId>
            <version>${{revision}}</version>
        </dependency>
"""
needle = "</dependencies>"
if needle in s and f"<artifactId>${module_name}</artifactId>" not in s:
    s = s.replace(needle, block + "\n    </dependencies>", 1)
p.write_text(s, encoding="utf-8")
PY
}

sync_frontend_generated() {
  local frontend_root="$1"
  local found=0

  mkdir -p "${frontend_root}/src"

  while IFS= read -r src_dir; do
    [[ -n "${src_dir}" ]] || continue
    found=1
    cp -R "${src_dir}/." "${frontend_root}/src/"
    echo "Synced frontend src from ${src_dir}"
  done < <(find_generated_frontend_src_dirs)

  if [[ "${found}" -eq 0 ]]; then
    echo "No generated frontend src found"
  fi
}

sync_backend_generated() {
  local backend_root="$1"
  local found=0

  while IFS= read -r module_dir; do
    [[ -n "${module_dir}" ]] || continue
    found=1

    local module_name
    local target_module_dir

    module_name="$(basename "${module_dir}")"
    target_module_dir="${backend_root}/${module_name}"

    mkdir -p "${target_module_dir}"
    cp -R "${module_dir}/." "${target_module_dir}/"

    ensure_module_pom "${backend_root}" "${module_name}"
    ensure_root_module_declared "${backend_root}" "${module_name}"
    ensure_server_dependency "${backend_root}" "${module_name}"

    echo "Synced backend module ${module_name}"
  done < <(find_generated_modules)

  if [[ "${found}" -eq 0 ]]; then
    echo "No generated backend modules found"
  fi
}

commit_and_push() {
  local dir="$1"
  local msg="$2"

  cd "${dir}"
  git add -A

  if git diff --cached --quiet; then
    echo "No changes: ${dir}"
    return
  fi

  git commit -m "${msg}"
  git push origin HEAD
}

BACKEND_DIR="${WORK_DIR}/${BACKEND_REPO}"
FRONTEND_DIR="${WORK_DIR}/${FRONTEND_REPO}"

echo "==> Clone target repositories"
clone_target "${BACKEND_REPO}" "${BACKEND_DIR}"
clone_target "${FRONTEND_REPO}" "${FRONTEND_DIR}"

echo "==> Sync generated frontend"
sync_frontend_generated "${FRONTEND_DIR}"

echo "==> Sync generated backend"
sync_backend_generated "${BACKEND_DIR}"

echo "==> Commit and push"
commit_and_push "${BACKEND_DIR}" "chore: sync generated backend code"
commit_and_push "${FRONTEND_DIR}" "chore: sync generated frontend code"

echo "Done"
