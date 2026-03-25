#!/usr/bin/env zsh
set -euo pipefail

# 로컬 앱 중 Homebrew cask 후보를 찾는 감사 스크립트
# 출력:
# 1) apps-audit.csv         : 앱별 후보 cask
# 2) unmanaged-apps.txt     : brew cask로 직접 관리 중이 아닌 앱 후보
# 3) installed-casks.txt    : 현재 설치된 cask 목록

WORKDIR="${PWD}/brew-app-audit"
mkdir -p "$WORKDIR"

APPS_RAW="$WORKDIR/apps-raw.txt"
APPS_NORM="$WORKDIR/apps-normalized.txt"
INSTALLED_CASKS="$WORKDIR/installed-casks.txt"
INSTALLED_CASK_NAMES="$WORKDIR/installed-cask-names.txt"
CSV_OUT="$WORKDIR/apps-audit.csv"
UNMANAGED_OUT="$WORKDIR/unmanaged-apps.txt"
MAX_CANDIDATES=12

: > "$APPS_RAW"
: > "$APPS_NORM"
: > "$INSTALLED_CASKS"
: > "$INSTALLED_CASK_NAMES"
: > "$CSV_OUT"
: > "$UNMANAGED_OUT"

collect_apps() {
  find /Applications "$HOME/Applications" -maxdepth 2 -type d -name "*.app" 2>/dev/null \
    | sed 's#.*/##' \
    | sed 's/\.app$//' \
    | awk 'NF && $0 !~ /^\./ && $0 != "Karabiner-EventViewer"' \
    | sort -fu
}

normalize_name() {
  local name="$1"
  local normalized

  normalized="$({
    printf '%s\n' "$name" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[[:space:]_-]+/-/g' \
      | sed -E 's/[^a-z0-9.+-]//g' \
      | sed -E 's/^-+//; s/-+$//'
  } | tr -d '\n')"

  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$normalized"
  else
    printf '__EMPTY__:%s\n' "$name"
  fi
}

resolve_alias_name() {
  local app_name="$1"

  case "$app_name" in
    "iTerm")
      echo "iterm2"
      ;;
    "Hidden Bar")
      echo "hiddenbar"
      ;;
    "Tailscale")
      echo "tailscale-app"
      ;;
    "VS Code"|"Visual Studio Code")
      echo "visual-studio-code"
      ;;
    "DataGrip")
      echo "datagrip"
      ;;
    "IINA")
      echo "iina"
      ;;
    "Microsoft Excel")
      echo "microsoft-excel"
      ;;
    "Microsoft PowerPoint")
      echo "microsoft-powerpoint"
      ;;
    "Microsoft Word")
      echo "microsoft-word"
      ;;
    "OmniDiskSweeper")
      echo "omnidisksweeper"
      ;;
    "Postman")
      echo "postman"
      ;;
    "Google 번역"|"Google 번역")
      echo "google-translate"
      ;;
    "Google 지도"|"Google 지도")
      echo "google-maps"
      ;;
    "Google 어스"|"Google 어스")
      echo "google-earth-pro"
      ;;
    "카카오톡"|"KakaoTalk")
      echo "kakaotalk"
      ;;
    "야놀자")
      echo "yanolja"
      ;;
    *)
      echo ""
      ;;
  esac
}

should_skip_candidate_search() {
  local app_name="$1"

  case "$app_name" in
    "넷플릭스"|"넷플릭스"|"네이버 지도"|"네이버 지도"|"미세미세"|"미세미세")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_effective_normalized_name() {
  local norm_name="$1"

  if [[ -z "$norm_name" ]]; then
    return 1
  fi

  if [[ "$norm_name" == __EMPTY__:* ]]; then
    return 1
  fi

  return 0
}

contains_non_ascii() {
  local value="$1"

  if printf '%s' "$value" | LC_ALL=C grep -q '[^ -~]'; then
    return 0
  fi

  return 1
}

already_managed_by_brew() {
  local app_name="$1"
  local norm_app="$2"
  local alias_name="$3"

  if [[ -n "$norm_app" ]] && grep -Fqx "$norm_app" "$INSTALLED_CASKS"; then
    return 0
  fi

  if [[ -n "$alias_name" ]] && grep -Fqx "$alias_name" "$INSTALLED_CASKS"; then
    return 0
  fi

  if grep -Fiqx -- "$app_name" "$INSTALLED_CASK_NAMES"; then
    return 0
  fi

  return 1
}

search_candidates() {
  local query="$1"

  if [[ -z "$query" ]]; then
    return 0
  fi

  if [[ "${#query}" -lt 2 ]]; then
    return 0
  fi

  brew search --cask --desc "$query" 2>/dev/null \
    | awk 'NF && $0 !~ /^==> Casks$/' \
    | head -n "$MAX_CANDIDATES" \
    || true
}

emit_alias_candidate() {
  local token="$1"

  if [[ -z "$token" ]]; then
    return 0
  fi

  if brew info --cask "$token" --json=v2 >/dev/null 2>&1; then
    printf '%s\n' "$token"
  fi
}

build_installed_cask_names() {
  if [[ ! -s "$INSTALLED_CASKS" ]]; then
    return 0
  fi

  ruby -rjson -rshellwords -e '
    STDIN.each_line(chomp: true) do |token|
      next if token.empty?
      json = `brew info --cask #{token.shellescape} --json=v2 2>/dev/null`
      next if json.nil? || json.empty?

      data = JSON.parse(json)
      casks = data["casks"] || []
      casks.each do |cask|
        ([cask["token"]] + Array(cask["name"]))
          .compact
          .map(&:to_s)
          .map(&:strip)
          .reject(&:empty?)
          .each { |name| puts name }
      end
    end
  ' < "$INSTALLED_CASKS" | sort -fu > "$INSTALLED_CASK_NAMES"
}

count_lines() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    awk 'END { print NR+0 }' "$file_path"
  else
    echo 0
  fi
}

print_progress() {
  local current="$1"
  local total="$2"
  local app_name="$3"
  printf '\r[%s/%s] Processing: %s' "$current" "$total" "$app_name" >&2
}

collect_apps > "$APPS_RAW"
while IFS= read -r app_name; do
  normalize_name "$app_name"
done < "$APPS_RAW" > "$APPS_NORM"

brew list --cask 2>/dev/null | sort -fu > "$INSTALLED_CASKS"
build_installed_cask_names

echo "app_name,normalized_name,is_brew_managed,cask_candidates" > "$CSV_OUT"

total_apps="$(count_lines "$APPS_RAW")"
current_index=0

while IFS= read -r app_name; do
  current_index=$((current_index + 1))
  print_progress "$current_index" "$total_apps" "$app_name"

  norm_name="$(normalize_name "$app_name")"
  alias_name="$(resolve_alias_name "$app_name")"

  managed="no"
  candidates=""
  if already_managed_by_brew "$app_name" "$norm_name" "$alias_name"; then
    managed="yes"
  else
    echo "$app_name" >> "$UNMANAGED_OUT"
    if ! should_skip_candidate_search "$app_name"; then
      candidates="$({
          if [[ -n "$alias_name" ]]; then
            emit_alias_candidate "$alias_name"
            search_candidates "$alias_name"
          fi
          if [[ -z "$alias_name" ]] && ! contains_non_ascii "$app_name"; then
            search_candidates "$app_name"
          fi
          if [[ -z "$alias_name" ]] && is_effective_normalized_name "$norm_name" && [[ "$norm_name" != "$app_name" ]] && ! contains_non_ascii "$norm_name"; then
            search_candidates "$norm_name"
          fi
        } \
          | awk 'NF' \
          | sort -fu \
          | head -n "$MAX_CANDIDATES" \
          | paste -sd ';' -
      )"
    fi
  fi

  candidates="${candidates//\"/\"\"}"

  echo "\"$app_name\",\"$norm_name\",\"$managed\",\"$candidates\"" >> "$CSV_OUT"
done < "$APPS_RAW"

printf '\n' >&2

total_installed_casks="$(count_lines "$INSTALLED_CASKS")"
total_unmanaged_apps="$(count_lines "$UNMANAGED_OUT")"

echo ""
echo "Done:"
echo "- Total apps: $total_apps"
echo "- Installed casks: $total_installed_casks"
echo "- Unmanaged apps: $total_unmanaged_apps"
echo "- CSV: $CSV_OUT"
echo "- Unmanaged app list: $UNMANAGED_OUT"
echo "- Installed cask list: $INSTALLED_CASKS"
echo "- Installed cask name list: $INSTALLED_CASK_NAMES"