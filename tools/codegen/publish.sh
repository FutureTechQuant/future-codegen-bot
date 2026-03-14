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

git config --global user.name "future-codegen-bot"
git config --global user.email "actions@users.noreply.github.com"

mkdir -p "${WORK_DIR}"

ensure_repo() {
  local repo="$1"
  local upstream="$2"
  local seed_dir="${WORK_DIR}/seed-${repo}"

  if gh repo view "${OWNER}/${repo}" >/dev/null 2>&1; then
    echo "Repo exists: ${OWNER}/${repo}"
    return
  fi

  rm -rf "${seed_dir}"
  git clone --depth 1 "${upstream}" "${seed_dir}"

  # 把 Gitee 的 origin 改成 upstream，给 GitHub 的 origin 腾位置
  if git -C "${seed_dir}" remote get-url origin >/dev/null 2>&1; then
    git -C "${seed_dir}" remote rename origin upstream
  fi

  gh repo create "${OWNER}/${repo}" \
    --private \
    --source "${seed_dir}" \
    --remote origin \
    --push
}

clone_target() {
  local repo="$1"
  local dir="$2"
  rm -rf "${dir}"
  git clone "https://x-access-token:${GH_TOKEN}@github.com/${OWNER}/${repo}.git" "${dir}"
}

copy_one() {
  local src_file="$1"
  local dst_root="$2"
  mkdir -p "${dst_root}/$(dirname "${src_file}")"
  cp -f "${src_file}" "${dst_root}/${src_file}"
}

sync_generated() {
  local backend_root="$1"
  local frontend_root="$2"

  shopt -s nullglob
  for gen_dir in "${OUT_DIR}"/*; do
    [[ -d "${gen_dir}" ]] || continue

    (
      cd "${gen_dir}"
      while IFS= read -r -d '' f; do
        rel="${f#./}"

        case "${rel}" in
          src/*|*.vue|*.ts|*.js|*.tsx|*.jsx)
            copy_one "${rel}" "${frontend_root}"
            ;;
          *)
            copy_one "${rel}" "${backend_root}"
            ;;
        esac
      done < <(find . -type f -print0)
    )
  done
}

commit_and_push() {
  local dir="$1"
  local msg="$2"

  cd "${dir}"
  git add .

  if git diff --cached --quiet; then
    echo "No changes: ${dir}"
    return
  fi

  git commit -m "${msg}"
  git push origin HEAD
}

ensure_repo "${BACKEND_REPO}" "${BACKEND_UPSTREAM}"
ensure_repo "${FRONTEND_REPO}" "${FRONTEND_UPSTREAM}"

BACKEND_DIR="${WORK_DIR}/${BACKEND_REPO}"
FRONTEND_DIR="${WORK_DIR}/${FRONTEND_REPO}"

clone_target "${BACKEND_REPO}" "${BACKEND_DIR}"
clone_target "${FRONTEND_REPO}" "${FRONTEND_DIR}"

sync_generated "${BACKEND_DIR}" "${FRONTEND_DIR}"

commit_and_push "${BACKEND_DIR}" "chore: sync generated backend code"
commit_and_push "${FRONTEND_DIR}" "chore: sync generated frontend code"
