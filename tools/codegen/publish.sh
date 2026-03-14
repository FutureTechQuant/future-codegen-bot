#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/out/generated"
WORK_DIR="${ROOT}/out/publish"

OWNER="${GITHUB_OWNER:-FutureTechQuant}"
BACKEND_REPO="ruoyi-vue-pro"
FRONTEND_REPO="yudao-ui-admin-vue3"

BACKEND_UPSTREAM="https://gitee.com/zhijiantianya/ruoyi-vue-pro.git"
FRONTEND_UPSTREAM="https://gitee.com/yudaocode/yudao-ui-admin-vue3.git"

TARGET_REPO_VISIBILITY="${TARGET_REPO_VISIBILITY:-private}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: missing env ${name}"
    exit 1
  fi
}

git config --global user.name "future-codegen-bot"
git config --global user.email "actions@users.noreply.github.com"

require_env GH_TOKEN
mkdir -p "${WORK_DIR}"

repo_url() {
  local repo="$1"
  echo "https://x-access-token:${GH_TOKEN}@github.com/${OWNER}/${repo}.git"
}

delete_repo_if_exists() {
  local repo="$1"

  if gh repo view "${OWNER}/${repo}" >/dev/null 2>&1; then
    echo "Deleting ${OWNER}/${repo}"
    gh api -X DELETE "repos/${OWNER}/${repo}"

    for _ in $(seq 1 60); do
      if ! gh repo view "${OWNER}/${repo}" >/dev/null 2>&1; then
        echo "Deleted ${OWNER}/${repo}"
        return
      fi
      sleep 2
    done

    echo "ERROR: timed out waiting for ${OWNER}/${repo} deletion"
    exit 1
  fi
}

create_empty_repo() {
  local repo="$1"

  if [[ "${TARGET_REPO_VISIBILITY}" == "public" ]]; then
    gh repo create "${OWNER}/${repo}" --public
  else
    gh repo create "${OWNER}/${repo}" --private
  fi
}

seed_repo_from_upstream() {
  local repo="$1"
  local upstream="$2"
  local bare_dir="${WORK_DIR}/seed-${repo}.git"

  rm -rf "${bare_dir}"
  git clone --bare "${upstream}" "${bare_dir}"

  create_empty_repo "${repo}"

  git -C "${bare_dir}" push --mirror "$(repo_url "${repo}")"
}

clone_target() {
  local repo="$1"
  local dir="$2"

  rm -rf "${dir}"
  git clone "$(repo_url "${repo}")" "${dir}"
}

copy_one() {
  local src_file="$1"
  local dst_root="$2"

  mkdir -p "${dst_root}/$(dirname "${src_file}")"
  cp -f "${src_file}" "${dst_root}/${src_file}"
}

is_frontend_file() {
  local rel="$1"
  case "${rel}" in
    *.vue|*.ts|*.js|*.tsx|*.jsx|*.css|*.scss|*.sass|*.less|*.styl|*.json)
      return 0
      ;;
    src/views/*|src/api/*|src/store/*|src/router/*|src/components/*|src/layout/*|src/layouts/*|src/utils/*|src/hooks/*|src/plugins/*|src/styles/*|views/*|api/*|components/*)
      return 0
      ;;
    package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|vite.config.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

sync_generated() {
  local backend_root="$1"
  local frontend_root="$2"

  if [[ ! -d "${OUT_DIR}" ]]; then
    echo "ERROR: generated output not found: ${OUT_DIR}"
    exit 1
  fi

  shopt -s nullglob
  local found=0

  for gen_dir in "${OUT_DIR}"/*; do
    [[ -d "${gen_dir}" ]] || continue
    found=1

    (
      cd "${gen_dir}"
      while IFS= read -r -d '' f; do
        rel="${f#./}"

        if is_frontend_file "${rel}"; then
          copy_one "${rel}" "${frontend_root}"
        else
          copy_one "${rel}" "${backend_root}"
        fi
      done < <(find . -type f -print0)
    )
  done

  if [[ "${found}" -eq 0 ]]; then
    echo "ERROR: no generated module directories under ${OUT_DIR}"
    exit 1
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

echo "==> Recreate target repositories"
delete_repo_if_exists "${BACKEND_REPO}"
delete_repo_if_exists "${FRONTEND_REPO}"

echo "==> Seed repositories from Gitee upstream"
seed_repo_from_upstream "${BACKEND_REPO}" "${BACKEND_UPSTREAM}"
seed_repo_from_upstream "${FRONTEND_REPO}" "${FRONTEND_UPSTREAM}"

BACKEND_DIR="${WORK_DIR}/${BACKEND_REPO}"
FRONTEND_DIR="${WORK_DIR}/${FRONTEND_REPO}"

echo "==> Clone fresh target repositories"
clone_target "${BACKEND_REPO}" "${BACKEND_DIR}"
clone_target "${FRONTEND_REPO}" "${FRONTEND_DIR}"

echo "==> Copy generated code"
sync_generated "${BACKEND_DIR}" "${FRONTEND_DIR}"

echo "==> Commit and push generated code"
commit_and_push "${BACKEND_DIR}" "chore: sync generated backend code"
commit_and_push "${FRONTEND_DIR}" "chore: sync generated frontend code"

echo "Done"
