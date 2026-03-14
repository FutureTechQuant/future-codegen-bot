#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/out/generated"
WORK_DIR="${ROOT}/out/publish"

OWNER="${GITHUB_OWNER:-FutureTechQuant}"
BACKEND_REPO="ruoyi-vue-pro"
FRONTEND_REPO="yudao-ui-admin-vue3"
BACKEND_BRANCH="${BACKEND_BRANCH:-master-jdk17}"

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

clone_target() {
  local repo="$1"
  local dir="$2"
  local branch="${3:-}"

  rm -rf "${dir}"
  if [[ -n "${branch}" ]]; then
    git clone --branch "${branch}" --single-branch "$(repo_url "${repo}")" "${dir}"
  else
    git clone "$(repo_url "${repo}")" "${dir}"
  fi
}

commit_and_push() {
  local dir="$1"
  local msg="$2"
  local branch="${3:-}"

  cd "${dir}"
  git add -A

  if git diff --cached --quiet; then
    echo "No changes: ${dir}"
    return
  fi

  git commit -m "${msg}"

  if [[ -n "${branch}" ]]; then
    git push -u origin "HEAD:${branch}"
  else
    git push origin HEAD
  fi
}

git config --global user.name "future-codegen-bot"
git config --global user.email "actions@users.noreply.github.com"

require_env GH_TOKEN
mkdir -p "${WORK_DIR}"

BACKEND_DIR="${WORK_DIR}/${BACKEND_REPO}"
FRONTEND_DIR="${WORK_DIR}/${FRONTEND_REPO}"

echo "==> Clone target repositories"
clone_target "${BACKEND_REPO}" "${BACKEND_DIR}" "${BACKEND_BRANCH}"
clone_target "${FRONTEND_REPO}" "${FRONTEND_DIR}"

echo "==> Sync generated code"
python3 "${ROOT}/tools/codegen/publish_sync.py" \
  --generated-dir "${OUT_DIR}" \
  --backend-root "${BACKEND_DIR}" \
  --frontend-root "${FRONTEND_DIR}"

echo "==> Commit and push"
commit_and_push "${BACKEND_DIR}" "chore: sync generated backend code" "${BACKEND_BRANCH}"
commit_and_push "${FRONTEND_DIR}" "chore: sync generated frontend code"

echo "Done"
