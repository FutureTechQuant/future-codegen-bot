#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/out/generated"
WORK_DIR="${ROOT}/out/publish"

OWNER="${GITHUB_OWNER:-FutureTechQuant}"
BACKEND_REPO="ruoyi-vue-pro"
FRONTEND_REPO="yudao-ui-admin-vue3"
BACKEND_BRANCH="${BACKEND_BRANCH:-master-jdk17}"

# Gitee 源仓库
GITEE_BACKEND_URL="https://gitee.com/zhijiantianya/ruoyi-vue-pro.git"
GITEE_FRONTEND_URL="https://gitee.com/yudaocode/yudao-ui-admin-vue3.git"

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

delete_repo_if_exists() {
  local repo="$1"
  local token="${GH_TOKEN}"
  local owner="${OWNER}"
  local url="https://api.github.com/repos/${owner}/${repo}"

  echo "==> Check & delete repo if exists: ${owner}/${repo}"
  status=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${url}")

  if [[ "${status}" == "404" ]]; then
    echo "Repo ${owner}/${repo} not found, skip delete"
    return
  fi

  if [[ "${status}" != "200" ]]; then
    echo "WARN: unexpected status when getting ${owner}/${repo}: ${status}"
  fi

  del_status=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${url}")

  if [[ "${del_status}" == "204" ]]; then
    echo "Deleted repo ${owner}/${repo}"
  else
    echo "ERROR: failed to delete ${owner}/${repo}, status=${del_status}"
    exit 1
  fi
}

create_repo() {
  local repo="$1"
  local description="$2"
  local private_flag="$3" # true / false

  local token="${GH_TOKEN}"
  local owner="${OWNER}"

  echo "==> Create repo ${owner}/${repo}"
  payload=$(jq -n \
    --arg name "${repo}" \
    --arg desc "${description}" \
    --argjson private "${private_flag}" \
    '{name: $name, private: $private, description: $desc, auto_init: false}')

  create_status=$(curl -sS -o /tmp/create-"${repo}".json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "https://api.github.com/orgs/${owner}/repos")

  if [[ "${create_status}" != "201" ]]; then
    echo "ERROR: failed to create repo ${owner}/${repo}, status=${create_status}"
    cat /tmp/create-"${repo}".json || true
    exit 1
  fi

  echo "Created repo ${owner}/${repo}"
}

create_repo_from_gitee() {
  local repo="$1"
  local gitee_url="$2"
  local description="$3"

  local tmp_dir="${WORK_DIR}/gitee-${repo}"
  rm -rf "${tmp_dir}"
  mkdir -p "${tmp_dir}"

  echo "==> Clone from Gitee: ${gitee_url}"
  git clone --mirror "${gitee_url}" "${tmp_dir}"

  # 在 GitHub 创建 org 仓库
  create_repo "${repo}" "${description}" true

  # 推送到 GitHub
  cd "${tmp_dir}"
  git remote set-url origin "$(repo_url "${repo}")"
  echo "==> Push mirror to GitHub ${OWNER}/${repo}"
  git push --mirror
}

clone_target() {
  local repo="$1"
  local dir="$2"
  local branch="${3:-}"

  rm -rf "${dir}"

  if [[ -n "${branch}" ]]; then
    if git ls-remote --heads "$(repo_url "${repo}")" "${branch}" >/dev/null 2>&1; then
      echo "Cloning ${repo} branch ${branch}"
      git clone --branch "${branch}" --single-branch "$(repo_url "${repo}")" "${dir}"
    else
      echo "Branch ${branch} not found in ${repo}, cloning default branch"
      git clone "$(repo_url "${repo}")" "${dir}"
    fi
  else
    echo "Cloning ${repo} default branch"
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

echo "==> Delete existing GitHub repos if any"
delete_repo_if_exists "${BACKEND_REPO}"
delete_repo_if_exists "${FRONTEND_REPO}"

echo "==> Recreate repos from Gitee"
create_repo_from_gitee "${BACKEND_REPO}" "${GITEE_BACKEND_URL}" "Backend repo synced from Gitee + codegen"
create_repo_from_gitee "${FRONTEND_REPO}" "${GITEE_FRONTEND_URL}" "Frontend repo synced from Gitee + codegen"

echo "==> Clone recreated GitHub repos"
clone_target "${BACKEND_REPO}" "${BACKEND_DIR}" "${BACKEND_BRANCH}"
clone_target "${FRONTEND_REPO}" "${FRONTEND_DIR}"

echo "==> Sync generated code into GitHub repos"
python3 "${ROOT}/tools/codegen/publish_sync.py" \
  --generated-dir "${OUT_DIR}" \
  --backend-root "${BACKEND_DIR}" \
  --frontend-root "${FRONTEND_DIR}"

echo "==> Commit and push"
commit_and_push "${BACKEND_DIR}" "chore: sync generated backend code" "${BACKEND_BRANCH}"
commit_and_push "${FRONTEND_DIR}" "chore: sync generated frontend code"

echo "Done"
