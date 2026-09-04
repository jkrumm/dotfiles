#!/usr/bin/env bash
# IU unified-endpoint validator.
#
# Probes every transport, health-checks the models listed in models.txt,
# and diffs the live catalog to surface notable models not yet configured.
# The API key is read from Keychain and never printed.
#
# Usage: validate.sh [--quick]   (--quick skips catalog discovery + Hermes)
set -uo pipefail

QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1

KEY=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
BASE=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null); BASE="${BASE%/}"
if [[ -z "$KEY" || -z "$BASE" ]]; then
  echo "ERROR: claude-sdk-api-key / claude-sdk-base-url missing in Keychain — run 'make setup' in dotfiles" >&2
  exit 1
fi
HOST="${BASE%/anthropic}"                       # https://<iu-unified-endpoint>
OPENAI="$HOST/openai/v1"
ANTHRO="$HOST/anthropic/v1"

# Locate the tracked model roster (provider/model per line, # comments allowed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/models.txt"
[[ -f "$CFG" ]] || CFG=""

CATALOG=$(mktemp)
curl -sS --max-time 30 "$OPENAI/models" -H "Authorization: Bearer $KEY" -o "$CATALOG" 2>/dev/null
catalog_ok=0; jq -e '.data' "$CATALOG" >/dev/null 2>&1 && catalog_ok=1

# Classify serving residency from a captured response header file → EU | US | ?
# Reads x-ms-region (Azure) and x-middleware-forwarded-server (gateway/backend).
residency() {
  local r f s
  r=$(awk -F': ' 'tolower($1)=="x-ms-region"{print $2}' "$1" 2>/dev/null | tr -d '\r' | head -1)
  f=$(awk -F': ' 'tolower($1)=="x-middleware-forwarded-server"{print $2}' "$1" 2>/dev/null | tr -d '\r' | head -1)
  s="$r | $f"
  if   echo "$s" | grep -qiE 'gdpr|sweden|france|germany|west *europe|italy|spain|poland|switzerland|norway|netherlands|europe-?west|vertex.*west1'; then echo "EU"
  elif echo "$s" | grep -qiE 'east *us|us *east|east-us|us-east|us-west|west *us|central *us|azure us'; then echo "US"
  else echo "? "; fi   # Nebius and bare passthroughs do not expose a region
}

# backend count + short owner for a model id (from catalog)
backends() {
  [[ $catalog_ok -eq 1 ]] || { echo "?|?"; return; }
  jq -r --arg m "$1" '
    (.data[] | select(.id==$m) | .owned_by) // "" |
    if . == "" then "0|(not in catalog)"
    else "\((split(",")|length))|\(.)" end' "$CATALOG" 2>/dev/null | head -1
}

echo "==================================================================="
echo " IU UNIFIED ENDPOINT — $HOST"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================================="

# ---------------------------------------------------------------- transports
echo ""
echo "## TRANSPORTS"
probe() { # name url authheader
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "$2" -H "$3" 2>/dev/null)
  printf "  %-12s %s  %s\n" "$1" "$code" "$([[ "$code" =~ ^(200|201|400|405)$ ]] && echo OK || echo CHECK)"
}
probe "openai"   "$OPENAI/models" "Authorization: Bearer $KEY"
probe "azure"    "$HOST/azure/openai/models?api-version=2024-02-01" "api-key: $KEY"
probe "gemini"   "$HOST/gemini/v1beta/models" "x-goog-api-key: $KEY"
probe "replicate" "$HOST/replicate/v1/models" "Authorization: Bearer $KEY"
# anthropic has no GET list — tiny POST
acode=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 25 "$ANTHRO/messages" \
  -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)
printf "  %-12s %s  %s\n" "anthropic" "$acode" "$([[ "$acode" == 200 ]] && echo OK || echo CHECK)"

# --------------------------------------------------- configured-model health
echo ""
echo "## CONFIGURED MODELS  (status · residency · latency · backends)"
echo "   residency: EU = EU region/GDPR gateway · US = US region · ? = backend region not exposed (e.g. Nebius)"
if [[ -z "$CFG" ]]; then
  echo "  (models.txt not found — skipping)"
else
  # emit "provider<TAB>modelid" per configured model, split on the FIRST slash
  # (the model id itself may contain further slashes, e.g. a Qwen HF-style path)
  grep -vE '^\s*(#|$)' "$CFG" | sed -E 's#^([^/]+)/(.+)$#\1\t\2#' |
  while IFS=$'\t' read -r prov model; do
    if [[ "$prov" == *anthropic* ]]; then
      url="$ANTHRO/messages"; auth=(-H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01")
      body="{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
    else
      url="$OPENAI/chat/completions"; auth=(-H "Authorization: Bearer $KEY")
      # GPT-5 reasoning models reject max_tokens — they require max_completion_tokens.
      if [[ "$model" == gpt-5* ]]; then tok='"max_completion_tokens":16'; else tok='"max_tokens":16'; fi
      body="{\"model\":\"$model\",$tok,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
    fi
    hdrf=$(mktemp)
    res=$(curl -sS -D "$hdrf" -o /dev/null -w "%{http_code} %{time_total}" --max-time 30 "$url" "${auth[@]}" -H "Content-Type: application/json" -d "$body" 2>/dev/null)
    code="${res%% *}"; secs="${res##* }"
    case "$code" in
      200) st="ok       " ;;
      429) st="THROTTLED" ;;
      000) st="TIMEOUT  " ;;
      *)   st="ERR($code)" ;;
    esac
    reg=$([[ "$code" == 200 ]] && residency "$hdrf" || echo "? "); rm -f "$hdrf"
    bk=$(backends "$model"); cnt="${bk%%|*}"; owner="${bk#*|}"
    printf "  %-9s %-2s %-40s %ss  backends=%s  %.34s\n" "$st" "$reg" "$prov/$model" "$secs" "$cnt" "$owner"
  done
fi

[[ $QUICK -eq 1 ]] && { rm -f "$CATALOG"; exit 0; }

# ------------------------------------------------ notable catalog / new models
echo ""
echo "## NOTABLE CHAT MODELS IN CATALOG  ([cfg]=configured, [NEW]=available, not configured)"
if [[ $catalog_ok -eq 1 ]]; then
  configured=$(grep -vE '^\s*(#|$)' "$CFG" 2>/dev/null | sed -E 's#^[^/]+/##' | sort -u)
  NOTABLE='claude-(opus|sonnet|haiku)-4|^gpt-5|gemini-3|gemini-2\.5-pro|Kimi|^GLM-[0-9]|MiniMax-M|Qwen3.*(Coder|397B|235B|Thinking)|DeepSeek-V|mistral-large|codestral|devstral|magistral|Hermes-[0-9]|^sonar'
  EXCLUDE='embed|tts|image|audio|realtime|transcribe|moderation|search-preview|dall-e|whisper|ocr|voxtral|robotics|computer-use|-live|native-audio|customtools'
  jq -r '.data[] | "\(.id)\t\(.owned_by // "")"' "$CATALOG" 2>/dev/null |
    grep -Ei "$NOTABLE" | grep -Eiv "$EXCLUDE" | sort |
    while IFS=$'\t' read -r id owner; do
      cnt=$(( $(grep -o ',' <<<"$owner" | wc -l) + 1 )); [[ -z "$owner" ]] && cnt=0
      if grep -qxF "$id" <<<"$configured"; then tag="[cfg]"; else tag="[NEW]"; fi
      printf "  %-5s %-44s backends=%s  %.42s\n" "$tag" "$id" "$cnt" "$owner"
    done
else
  echo "  (catalog fetch failed)"
fi

# --------------------------------------------------------------------- Hermes
echo ""
echo "## HERMES AGENT"
HERMES="$HOME/SourceRoot/hermes-agent"
if [[ -d "$HERMES" ]]; then
  echo "  Configured model references found (grep):"
  grep -rEoh '(Kimi-K2\.[0-9]|claude-[a-z0-9.-]+|gpt-5[a-z0-9.-]*|gemini-[0-9][a-z0-9.-]*|GLM-[0-9]|MiniMax-M[0-9.]+|deepseek[a-z0-9./-]*)' \
    "$HERMES" --include='*.ts' --include='*.js' --include='*.json' --include='*.env*' --include='*.toml' --include='*.yaml' --include='*.yml' 2>/dev/null \
    | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'
  [[ -z "$(grep -rEl 'Kimi|claude-|gpt-5|gemini-' "$HERMES" 2>/dev/null | head -1)" ]] && echo "    (no model id found)"
else
  echo "  (~/SourceRoot/hermes-agent not present on this machine)"
fi

rm -f "$CATALOG"
echo ""
echo "Done. (Kimi-K2.6 = 1 backend / throttle-prone; Kimi-K2.5 = 2 backends / steadier.)"
