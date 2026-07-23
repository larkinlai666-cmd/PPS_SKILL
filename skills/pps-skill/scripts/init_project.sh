#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: init_project.sh <project-name> [--profile standard|evidence] [--parent DIR] [--git-name NAME --git-email EMAIL] [--install-hook] [--no-git]"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

project_name="$1"
shift
profile="standard"
parent="${PPS_PROJECT_HOME:-${PLAN_PROJECT_HOME:-$HOME/Projects}}"
no_git=0
install_hook=0
git_name=""
git_email=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      profile="$2"
      shift 2
      ;;
    --parent)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      parent="$2"
      shift 2
      ;;
    --no-git)
      no_git=1
      shift
      ;;
    --install-hook)
      install_hook=1
      shift
      ;;
    --git-name)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      git_name="$2"
      shift 2
      ;;
    --git-email)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      git_email="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$git_name" && -z "$git_email" ]] || [[ -z "$git_name" && -n "$git_email" ]]; then
  echo "Provide both --git-name and --git-email, or neither." >&2
  exit 1
fi
if (( no_git == 1 && install_hook == 1 )); then
  echo "--install-hook cannot be used with --no-git." >&2
  exit 1
fi
if (( no_git == 1 )) && [[ -n "$git_name" ]]; then
  echo "--git-name/--git-email cannot be used with --no-git." >&2
  exit 1
fi

[[ "$project_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Project name may contain only letters, digits, dot, underscore, and hyphen." >&2
  exit 1
}
[[ "$project_name" != "." && "$project_name" != ".." ]] || {
  echo "Project name cannot be '.' or '..'." >&2
  exit 1
}
(( ${#project_name} <= 100 )) || {
  echo "Project name cannot exceed 100 characters." >&2
  exit 1
}
[[ "$project_name" != *. ]] || {
  echo "Project name cannot end with a dot." >&2
  exit 1
}
portable_base="$(printf '%s' "${project_name%%.*}" | tr '[:lower:]' '[:upper:]')"
case "$portable_base" in
  CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
    echo "Project name uses a Windows-reserved device name: $project_name" >&2
    exit 1
    ;;
esac
[[ "$profile" == "standard" || "$profile" == "evidence" ]] || {
  echo "Profile must be standard or evidence." >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_root="$(cd "$script_dir/.." && pwd -P)"
template_root="$skill_root/assets/templates"
target="${parent%/}/$project_name"

if [[ -e "$target" ]]; then
  [[ -d "$target" ]] || {
    echo "Target exists and is not a directory: $target" >&2
    exit 1
  }
  if [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refusing to initialize a non-empty target: $target" >&2
    exit 1
  fi
else
  mkdir -p "$target"
fi
mkdir -p "$target/docs" "$target/assets" "$target/prototypes" "$target/scripts"

timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
date_value="$(date -u '+%Y-%m-%d')"
device="$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-' || true)"
device="${device:-unknown-device}"
main_artifact="docs/MAIN.md"
if [[ "$profile" == "evidence" ]]; then
  coverage_artifact="docs/CURRENT_REVIEW_EVIDENCE.md"
else
  coverage_artifact="CONTEXT.md"
fi

render() {
  local source="$1"
  local destination="$2"
  sed \
    -e "s|{{PROJECT_NAME}}|$project_name|g" \
    -e "s|{{PROFILE}}|$profile|g" \
    -e "s|{{TIMESTAMP}}|$timestamp|g" \
    -e "s|{{DATE}}|$date_value|g" \
    -e "s|{{DEVICE}}|$device|g" \
    -e "s|{{MAIN_ARTIFACT}}|$main_artifact|g" \
    -e "s|{{COVERAGE_ARTIFACT}}|$coverage_artifact|g" \
    "$template_root/$source" > "$destination"
}

render PROJECT_README.md "$target/README.md"
render AGENTS.md "$target/AGENTS.md"
render PROJECT_STATE.md "$target/PROJECT_STATE.md"
render DECISIONS.md "$target/DECISIONS.md"
render CONTEXT.md "$target/CONTEXT.md"
render MAIN.md "$target/docs/MAIN.md"
render gitignore.template "$target/.gitignore"
render gitattributes.template "$target/.gitattributes"

if [[ "$profile" == "evidence" ]]; then
  render SOURCE_INDEX.md "$target/SOURCE_INDEX.md"
  render CURRENT_REVIEW_EVIDENCE.md "$target/docs/CURRENT_REVIEW_EVIDENCE.md"
fi

for script_name in \
  status_check.ps1 status_check.sh \
  validate_project.ps1 validate_project.sh \
  pre-commit pre-commit.ps1; do
  cp "$script_dir/$script_name" "$target/scripts/$script_name"
done
chmod +x "$target/scripts/"*.sh "$target/scripts/pre-commit"

if (( no_git == 0 )); then
  if command -v git >/dev/null 2>&1; then
    if ! git -C "$target" init --quiet -b main 2>/dev/null; then
      git -C "$target" init --quiet
      git -C "$target" checkout -q -b main 2>/dev/null ||
        git -C "$target" branch -M main
    fi
    git -C "$target" add --all
    if [[ -n "$git_name" ]]; then
      git -C "$target" config user.name "$git_name"
      git -C "$target" config user.email "$git_email"
    fi
    effective_name="$(git -C "$target" config --get user.name 2>/dev/null || true)"
    effective_email="$(git -C "$target" config --get user.email 2>/dev/null || true)"
    if [[ -z "$effective_name" || -z "$effective_email" ]]; then
      echo "WARNING: initial files are staged but not committed because Git identity is missing. Pass --git-name and --git-email for repository-local identity, or configure Git yourself." >&2
    elif ! git -C "$target" commit --quiet -m "chore: initialize PPS project"; then
      echo "WARNING: initial commit was not created; inspect Git output and commit manually." >&2
    fi
    if (( install_hook == 1 )); then
      cp "$script_dir/pre-commit" "$target/.git/hooks/pre-commit"
      chmod +x "$target/.git/hooks/pre-commit"
      echo "PPS pre-commit validation hook installed."
    fi
  else
    echo "WARNING: Git was not found; project files were created without a repository." >&2
  fi
fi

bash "$target/scripts/validate_project.sh" "$target"
echo "PPS project initialized: $target"
echo "Profile: $profile"
echo "Branch: $(git -C "$target" branch --show-current 2>/dev/null || printf 'not initialized')"
echo "Next: replace the bootstrap objective and prepare PKG-001."
