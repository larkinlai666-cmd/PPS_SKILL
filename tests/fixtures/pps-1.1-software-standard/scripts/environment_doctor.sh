#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: environment_doctor.sh [ROOT | --core] [--plan | --apply --yes]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
action="check"
confirmed=0
root_seen=0
core=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      [[ "$action" == "check" ]] || {
        usage >&2
        exit 2
      }
      action="plan"
      shift
      ;;
    --apply)
      [[ "$action" == "check" ]] || {
        usage >&2
        exit 2
      }
      action="apply"
      shift
      ;;
    --yes)
      confirmed=1
      shift
      ;;
    --core)
      (( root_seen == 0 && core == 0 )) || {
        usage >&2
        exit 2
      }
      core=1
      shift
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      (( root_seen == 0 )) || {
        usage >&2
        exit 2
      }
      root="$(cd "$1" && pwd -P)"
      root_seen=1
      shift
      ;;
  esac
done

if (( core == 1 && root_seen == 1 )); then
  usage >&2
  exit 2
fi

if [[ "$action" == "apply" && "$confirmed" -ne 1 ]]; then
  echo "ERROR: system installation requires both --apply and --yes." >&2
  exit 2
fi
if [[ "$action" != "apply" && "$confirmed" -eq 1 ]]; then
  echo "ERROR: --yes is valid only with --apply." >&2
  exit 2
fi

manifest="$root/ENVIRONMENT.md"

section_field() {
  local field="$1"
  awk -v field="$field" '
    /^## Toolchain Manifest[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && index($0, "- " field ":") == 1 {
      sub("^- " field ":[[:space:]]*", "")
      print
      exit
    }
  ' "$manifest"
}

project_command_field() {
  local field="$1"
  awk -v field="$field" '
    /^## Project Commands[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && index($0, "- " field ":") == 1 {
      sub("^- " field ":[[:space:]]*", "")
      print
      exit
    }
  ' "$manifest"
}

if (( core == 1 )); then
  required_raw="git,gh"
  optional_raw="rg,python,imagemagick,pandoc"
  dependency_raw="none"
  environment_verify="none"
  manager_policy="auto"
  install_policy="project-local-first"
else
  [[ -f "$manifest" ]] || {
    echo "ERROR: missing environment manifest: $manifest" >&2
    exit 1
  }
  required_raw="$(section_field Required)"
  optional_raw="$(section_field Optional)"
  dependency_raw="$(section_field "Dependency manifests")"
  dependency_raw="${dependency_raw:-none}"
  environment_verify="$(project_command_field "Environment verify")"
  environment_verify="${environment_verify:-none}"
  manager_policy="$(section_field "Package manager")"
  install_policy="$(section_field "Install policy")"
  [[ -n "$required_raw" && -n "$optional_raw" && -n "$manager_policy" && -n "$install_policy" ]] || {
    echo "ERROR: ENVIRONMENT.md has an incomplete Toolchain Manifest." >&2
    exit 1
  }
fi
[[ "$install_policy" == "project-local-first" ]] || {
  echo "ERROR: Install policy must be project-local-first." >&2
  exit 1
}
for entry in "required:$required_raw" "optional:$optional_raw"; do
  entry_label="${entry%%:*}"
  entry_value="${entry#*:}"
  if [[ "$entry_value" != "none" ]] &&
      { [[ "$entry_value" == ,* ]] || [[ "$entry_value" == *, ]] ||
        [[ "$entry_value" =~ ,[[:space:]]*, ]]; }; then
    echo "ERROR: $entry_label tool list contains an empty entry." >&2
    exit 1
  fi
done

split_tools() {
  local raw="$1"
  if [[ "$raw" == "none" ]]; then
    return 0
  fi
  printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_allowed_tool() {
  case "$1" in
    git|gh|rg|node|python|powershell|imagemagick|ffmpeg|pandoc|libreoffice|poppler|rclone) return 0 ;;
    *) return 1 ;;
  esac
}

tool_present() {
  case "$1" in
    python) command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 ;;
    powershell) command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1 ;;
    imagemagick) command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 ;;
    libreoffice)
      command -v libreoffice >/dev/null 2>&1 ||
        command -v soffice >/dev/null 2>&1 ||
        [[ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]]
      ;;
    poppler)
      command -v pdftotext >/dev/null 2>&1 &&
        command -v pdftoppm >/dev/null 2>&1
      ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

package_for() {
  local manager="$1"
  local tool="$2"
  case "$manager:$tool" in
    winget:git) echo "Git.Git" ;;
    winget:gh) echo "GitHub.cli" ;;
    winget:rg) echo "BurntSushi.ripgrep.MSVC" ;;
    winget:node) echo "OpenJS.NodeJS.LTS" ;;
    winget:python) echo "Python.Python.3.12" ;;
    winget:imagemagick) echo "ImageMagick.ImageMagick" ;;
    winget:ffmpeg) echo "Gyan.FFmpeg" ;;
    winget:pandoc) echo "JohnMacFarlane.Pandoc" ;;
    winget:powershell) echo "Microsoft.PowerShell" ;;
    winget:libreoffice) echo "TheDocumentFoundation.LibreOffice" ;;
    winget:rclone) echo "Rclone.Rclone" ;;
    apt:gh) echo "gh" ;;
    apt:rg) echo "ripgrep" ;;
    apt:node) echo "nodejs" ;;
    apt:python) echo "python3" ;;
    apt:imagemagick) echo "imagemagick" ;;
    apt:libreoffice) echo "libreoffice" ;;
    apt:poppler) echo "poppler-utils" ;;
    apt:rclone) echo "rclone" ;;
    apt:powershell) return 1 ;;
    apt:*) echo "$tool" ;;
    dnf:rg) echo "ripgrep" ;;
    dnf:node) echo "nodejs" ;;
    dnf:python) echo "python3" ;;
    dnf:imagemagick) echo "ImageMagick" ;;
    dnf:libreoffice) echo "libreoffice" ;;
    dnf:poppler) echo "poppler-utils" ;;
    dnf:rclone) echo "rclone" ;;
    dnf:powershell) return 1 ;;
    dnf:*) echo "$tool" ;;
    pacman:rg) echo "ripgrep" ;;
    pacman:node) echo "nodejs-lts-iron" ;;
    pacman:python) echo "python" ;;
    pacman:imagemagick) echo "imagemagick" ;;
    pacman:libreoffice) echo "libreoffice-fresh" ;;
    pacman:poppler) echo "poppler" ;;
    pacman:rclone) echo "rclone" ;;
    pacman:powershell) return 1 ;;
    pacman:*) echo "$tool" ;;
    brew:imagemagick) echo "imagemagick" ;;
    brew:poppler) echo "poppler" ;;
    brew:rclone) echo "rclone" ;;
    brew:powershell|brew:libreoffice) return 1 ;;
    brew:*) echo "$tool" ;;
    *) return 1 ;;
  esac
}

resolve_manager() {
  local selected
  local command_name
  case "$manager_policy" in
    brew|winget|apt|dnf|pacman|manual) selected="$manager_policy" ;;
    auto)
      if command -v brew >/dev/null 2>&1; then selected=brew
      elif command -v winget >/dev/null 2>&1; then selected=winget
      elif command -v apt-get >/dev/null 2>&1; then selected=apt
      elif command -v dnf >/dev/null 2>&1; then selected=dnf
      elif command -v pacman >/dev/null 2>&1; then selected=pacman
      else selected=manual
      fi
      ;;
    *)
      echo "ERROR: unsupported package manager policy: $manager_policy" >&2
      exit 1
      ;;
  esac
  case "$selected" in
    brew) command_name=brew ;;
    winget) command_name=winget ;;
    apt) command_name=apt-get ;;
    dnf) command_name=dnf ;;
    pacman) command_name=pacman ;;
    manual) echo manual; return ;;
  esac
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: selected package manager '$selected' is not installed." >&2
    exit 1
  }
  echo "$selected"
}

declare -a required_tools=()
declare -a optional_tools=()
declare -a missing_required=()
declare -a missing_optional=()
seen_required="|"
while IFS= read -r tool; do
  [[ -n "$tool" ]] || {
    echo "ERROR: required tool list contains an empty entry." >&2
    exit 1
  }
  is_allowed_tool "$tool" || {
    echo "ERROR: unsupported required tool: $tool" >&2
    exit 1
  }
  [[ "$seen_required" != *"|$tool|"* ]] || {
    echo "ERROR: duplicate required tool: $tool" >&2
    exit 1
  }
  seen_required="${seen_required}${tool}|"
  required_tools+=("$tool")
done < <(split_tools "$required_raw")
seen_optional="|"
while IFS= read -r tool; do
  [[ -n "$tool" ]] || {
    echo "ERROR: optional tool list contains an empty entry." >&2
    exit 1
  }
  is_allowed_tool "$tool" || {
    echo "ERROR: unsupported optional tool: $tool" >&2
    exit 1
  }
  [[ "$seen_optional" != *"|$tool|"* ]] || {
    echo "ERROR: duplicate optional tool: $tool" >&2
    exit 1
  }
  seen_optional="${seen_optional}${tool}|"
  optional_tools+=("$tool")
done < <(split_tools "$optional_raw")

for tool in "${required_tools[@]}"; do
  if tool_present "$tool"; then
    echo "PASS required: $tool"
  else
    echo "MISSING required: $tool"
    missing_required+=("$tool")
  fi
done
for tool in "${optional_tools[@]}"; do
  if tool_present "$tool"; then
    echo "PASS optional: $tool"
  else
    echo "MISSING optional: $tool"
    missing_optional+=("$tool")
  fi
done

if [[ "$dependency_raw" != "none" ]]; then
  while IFS= read -r rel; do
    rel="$(printf '%s' "$rel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$rel" || "$rel" == /* || "$rel" == *\\* ||
      "$rel" =~ ^[A-Za-z]:[\\/]|(^|/)\.\.(/|$) || ! -f "$root/$rel" ]]; then
      echo "ERROR: dependency manifest must be an existing safe project-relative file: $rel" >&2
      exit 1
    fi
    echo "PASS dependency manifest: $rel"
  done < <(printf '%s\n' "$dependency_raw" | tr ',' '\n')
fi
echo "Declared environment verify: $environment_verify"

if (( ${#missing_required[@]} == 0 )); then
  echo "Environment check passed."
  exit 0
fi

manager="$(resolve_manager)"
if [[ "$action" == "check" ]]; then
  echo "Environment check failed: ${#missing_required[@]} required tool(s) missing." >&2
  echo "Run with --plan to preview explicit installation commands." >&2
  exit 1
fi
if [[ "$manager" == "manual" ]]; then
  echo "ERROR: no supported package manager is available; install required tools manually." >&2
  exit 1
fi

declare -a packages=()
declare -a manual_tools=()
for tool in "${missing_required[@]}"; do
  if package_name="$(package_for "$manager" "$tool")"; then
    packages+=("$package_name")
  else
    manual_tools+=("$tool")
  fi
done

if (( ${#manual_tools[@]} > 0 )); then
  echo "ERROR: no safe automatic package mapping for '$manager': ${manual_tools[*]}." >&2
  echo "Install those capabilities manually or change the manifest/package-manager policy, then rerun check mode." >&2
  exit 1
fi

case "$manager" in
  brew) command_line=(brew install "${packages[@]}") ;;
  winget) command_line=() ;;
  apt)
    if [[ "$(id -u)" -eq 0 ]]; then
      command_line=(apt-get install -y "${packages[@]}")
    else
      command_line=(sudo apt-get install -y "${packages[@]}")
    fi
    ;;
  dnf)
    if [[ "$(id -u)" -eq 0 ]]; then
      command_line=(dnf install -y "${packages[@]}")
    else
      command_line=(sudo dnf install -y "${packages[@]}")
    fi
    ;;
  pacman)
    if [[ "$(id -u)" -eq 0 ]]; then
      command_line=(pacman -S --needed --noconfirm "${packages[@]}")
    else
      command_line=(sudo pacman -S --needed --noconfirm "${packages[@]}")
    fi
    ;;
esac

if [[ "$manager" == "winget" ]]; then
  for package in "${packages[@]}"; do
    printf 'Install plan: winget install --id %q --exact --accept-package-agreements --accept-source-agreements\n' "$package"
  done
else
  printf 'Install plan:'
  printf ' %q' "${command_line[@]}"
  printf '\n'
fi
echo "Optional tools are reported only; they are never auto-installed."
if [[ "$action" == "plan" ]]; then
  exit 1
fi

if [[ "$manager" == "winget" ]]; then
  for package in "${packages[@]}"; do
    winget install --id "$package" --exact \
      --accept-package-agreements --accept-source-agreements
  done
else
  "${command_line[@]}"
fi
echo "Installation command completed. Rechecking required tools..."
if (( core == 1 )); then
  exec "$0" --core
else
  exec "$0" "$root"
fi
