#!/bin/bash
# =============================================================================
# Adversarial-RAG: Benchmark Dataset Builder
# =============================================================================
# Builds triplets of (EVTX logs, Sigma rules, CTI references)
#
# Usage:
#   ./build_dataset.sh [--sigma | --zircolite] [--limit N]
#
# Arguments:
#   --sigma       Use original Sigma YAML rules from sigma/rules/ (slower)
#   --zircolite   Use pre-compiled Zircolite JSON rulesets (default, faster)
#   --limit N     Only process the first N EVTX files (useful for testing)
#
# Expected directory structure (run from sigmabench/):
#   .
#   ├── build_dataset.sh          ← this script
#   ├── data/evtx_samples/        ← EVTX files (by tactic folders)
#   ├── sigma/rules/              ← SigmaHQ YAML rules
#   └── zircolite/
#       ├── zircolite.py
#       └── rules/                ← pre-compiled rulesets (.json)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — all paths relative to script location
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EVTX_DIR="$SCRIPT_DIR/data/evtx_samples"
SIGMA_RULES_DIR="$SCRIPT_DIR/sigma/rules"
ZIRCOLITE_DIR="$SCRIPT_DIR/zircolite"
ZIRCOLITE_PY="$ZIRCOLITE_DIR/zircolite.py"

OUTPUT_DIR="$SCRIPT_DIR/output"
LOGS_DIR="$OUTPUT_DIR/logs"

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
RULE_SOURCE="zircolite" # default
LIMIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sigma)
            RULE_SOURCE="sigma"
            shift
            ;;
        --zircolite)
            RULE_SOURCE="zircolite"
            shift
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--sigma | --zircolite] [--limit N]"
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; }
log_step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
              echo -e "${BLUE}[STEP]${NC}  $1"; \
              echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: VALIDATE DIRECTORY STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 0: Validating directory structure"

ERRORS=0

if [ ! -d "$EVTX_DIR" ]; then
    log_error "Missing: data/evtx_samples/"
    ERRORS=$((ERRORS + 1))
fi

if [ ! -d "$SIGMA_RULES_DIR" ]; then
    log_error "Missing: sigma/rules/"
    ERRORS=$((ERRORS + 1))
fi

if [ ! -f "$ZIRCOLITE_PY" ]; then
    log_error "Missing: zircolite/zircolite.py"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    log_error "Fix the above errors and re-run."
    exit 1
fi

log_info "Directory structure OK."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: SETUP OUTPUT DIRS & INSTALL DEPS
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 1: Setup"

mkdir -p "$OUTPUT_DIR/raw_matches" "$OUTPUT_DIR/triplets" "$LOGS_DIR"

# Install Zircolite deps if needed
cd "$ZIRCOLITE_DIR"
pip3 install -r requirements.txt --quiet --break-system-packages 2>/dev/null || \
    pip3 install -r requirements.txt --quiet 2>/dev/null || true
cd "$SCRIPT_DIR"

# PyYAML for parsing Sigma originals
pip3 install pyyaml --quiet --break-system-packages 2>/dev/null || \
    pip3 install pyyaml --quiet 2>/dev/null || true

log_info "Dependencies ready."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: INDEX EVTX FILES
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 2: Indexing EVTX files"

EVTX_INDEX="$OUTPUT_DIR/evtx_index.txt"
find "$EVTX_DIR" -type f \( -name "*.evtx" -o -name "*.EVTX" \) | sort > "$EVTX_INDEX"

if [ "$LIMIT" -gt 0 ]; then
    head -n "$LIMIT" "$EVTX_INDEX" > "${EVTX_INDEX}.tmp" && mv "${EVTX_INDEX}.tmp" "$EVTX_INDEX"
    log_warn "Limiting processing to the first $LIMIT files."
fi

TOTAL_EVTX=$(wc -l < "$EVTX_INDEX")
log_info "Found $TOTAL_EVTX EVTX files in data/evtx_samples/"

if [ "$TOTAL_EVTX" -eq 0 ]; then
    log_error "No .evtx files found. Check data/evtx_samples/ contents."
    exit 1
fi

# Show sample of what we found
log_info "Sample files:"
head -5 "$EVTX_INDEX" | while read -r f; do
    echo "    $(echo "$f" | sed "s|$SCRIPT_DIR/||")"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: LOCATE RULESET
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 3: Locating ruleset"

RULESET=""

if [ "$RULE_SOURCE" == "sigma" ]; then
    RULESET="$SIGMA_RULES_DIR"
    log_info "Using original Sigma YAML rules from: $RULESET"
    
    # Count YAML files
    RULE_COUNT=$(find "$RULESET" -name "*.yml" -type f | wc -l)
else
    # Priority: sysmon > generic > any available
    for candidate in \
        "$ZIRCOLITE_DIR/rules/rules_windows_sysmon_pysigma.json" \
        "$ZIRCOLITE_DIR/rules/rules_windows_sysmon.json" \
        "$ZIRCOLITE_DIR/rules/rules_windows_generic_pysigma.json" \
        "$ZIRCOLITE_DIR/rules/rules_windows_generic.json"; do
        if [ -f "$candidate" ]; then
            RULESET="$candidate"
            break
        fi
    done

    # If none found, pick the first .json in rules/
    if [ -z "$RULESET" ]; then
        RULESET=$(find "$ZIRCOLITE_DIR/rules" -name "*.json" -type f | head -1)
    fi

    if [ -z "$RULESET" ] || [ ! -f "$RULESET" ]; then
        log_error "No compiled ruleset found in zircolite/rules/."
        log_error "Available files:"
        ls -la "$ZIRCOLITE_DIR/rules/" 2>/dev/null || echo "  (directory empty or missing)"
        exit 1
    fi

    log_info "Using Zircolite ruleset: $(basename "$RULESET")"
    RULE_COUNT=$(python3 -c "import json; print(len(json.load(open('$RULESET'))))" 2>/dev/null || echo "?")
fi

log_info "Ruleset contains $RULE_COUNT rules."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: RUN ZIRCOLITE ON EACH EVTX FILE
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 4: Running Zircolite (this may take a while)"

COUNTER=0
MATCH_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

while IFS= read -r evtx_file; do
    COUNTER=$((COUNTER + 1))

    # Build a safe output filename from the relative path
    relative_path="${evtx_file#$EVTX_DIR/}"
    safe_name=$(echo "$relative_path" | sed 's/[\/\\]/__/g' | sed 's/\.[eE][vV][tT][xX]$//')
    result_file="$OUTPUT_DIR/raw_matches/${safe_name}.json"

    # Skip if already processed
    if [ -f "$result_file" ]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    log_info "[$COUNTER/$TOTAL_EVTX] $(echo "$relative_path" | head -c 80)"

    # Run Zircolite — output goes to detected_events.json by default,
    # so we use --outfile to redirect
    temp_result="$LOGS_DIR/_zircolite_temp.json"
    rm -f "$temp_result"

    if python3 "$ZIRCOLITE_PY" \
        --evtx "$evtx_file" \
        --ruleset "$RULESET" \
        --config "$ZIRCOLITE_DIR/config/fieldMappings.yaml" \
        --outfile "$temp_result" \
        --quiet \
        2>"$LOGS_DIR/stderr_${safe_name}.log"; then

        if [ -f "$temp_result" ]; then
            mv "$temp_result" "$result_file"

            n_matches=$(python3 -c "
import json
try:
    data = json.load(open('$result_file'))
    print(len(data) if isinstance(data, list) else 0)
except:
    print(0)
" 2>/dev/null || echo "0")

            if [ "$n_matches" -gt 0 ]; then
                MATCH_COUNT=$((MATCH_COUNT + 1))
                log_info "  → $n_matches detection(s)"
            fi
        else
            # Zircolite ran OK but produced no output file = no detections
            echo '[]' > "$result_file"
        fi
    else
        log_warn "  Failed on: $relative_path"
        echo '[]' > "$result_file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

done < "$EVTX_INDEX"

echo ""
log_info "━━━ Zircolite Summary ━━━"
log_info "  Processed:  $COUNTER"
log_info "  Skipped:    $SKIP_COUNT (already done)"
log_info "  With hits:  $MATCH_COUNT"
log_info "  Failures:   $FAIL_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: BUILD TRIPLET DATASET (Python)
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 5: Building triplet dataset"

export EVTX_DIR SIGMA_RULES_DIR OUTPUT_DIR RULESET

python3 << 'PYTHON_SCRIPT'
import json
import os
import glob
import yaml
import re
import sys
from pathlib import Path
from collections import defaultdict

# ─── Paths from environment ───────────────────────────────────────────────
EVTX_DIR        = os.environ["EVTX_DIR"]
SIGMA_RULES_DIR = os.environ["SIGMA_RULES_DIR"]
OUTPUT_DIR      = os.environ["OUTPUT_DIR"]
RULESET_PATH    = os.environ["RULESET"]
RAW_DIR         = f"{OUTPUT_DIR}/raw_matches"

# ─── Reference URL classification ─────────────────────────────────────────
NON_CTI_PATTERNS = [
    r"attack\.mitre\.org",
    r"docs\.microsoft\.com",
    r"learn\.microsoft\.com",
    r"msdn\.microsoft\.com",
    r"technet\.microsoft\.com",
    r"github\.com",
    r"wikipedia\.org",
    r"stackoverflow\.com",
    r"twitter\.com",  r"x\.com",
    r"car\.mitre\.org",
    r"lolbas-project",
    r"atomicredteam",
    r"sigma\.wiki",
    r"youtube\.com",
]

CTI_PATTERNS = [
    r"thedfirreport\.com",
    r"trendmicro\.com.*security",
    r"securelist\.com",
    r"blog\.talosintelligence",
    r"unit42\.paloaltonetworks",
    r"mandiant\.com",
    r"crowdstrike\.com/blog",
    r"microsoft\.com/.*security.*blog",
    r"welivesecurity\.com",
    r"symantec.*blogs",
    r"fireeye\.com",
    r"sentinelone\.com.*blog",
    r"elastic\.co/.*security",
    r"redcanary\.com",
    r"splunk\.com.*blog",
    r"threatpost\.com",
    r"bleepingcomputer\.com",
    r"darkreading\.com",
    r"thehackernews\.com",
    r"cybereason\.com",
    r"proofpoint\.com.*blog",
    r"volexity\.com",
    r"recordedfuture\.com",
    r"sekoia\.io",
    r"malwarebytes\.com.*blog",
    r"adsecurity\.org",
    r"medium\.com",
    r"stealthbits\.com",
    r"varonis\.com",
    r"crowdstrike\.com",
    r"sentinelone\.com",
    r"cybereason\.com",
    r"fireeye\.com",
    r"mandiant\.com",
]

def classify_reference(url: str) -> str:
    url_lower = url.lower()
    for p in NON_CTI_PATTERNS:
        if re.search(p, url_lower):
            return "non_cti"
    for p in CTI_PATTERNS:
        if re.search(p, url_lower):
            return "cti"
    if re.search(r"(blog|report|threat|advisory|intelligence|incident|analysis|research)", url_lower):
        return "likely_cti"
    return "unknown"


def infer_tactic_from_path(evtx_path: str) -> str:
    """Infer ATT&CK tactic from folder name in evtx_samples/."""
    parts = evtx_path.replace("\\", "/").split("/")
    tactics = [
        "Credential Access", "Defense Evasion", "Discovery", "Execution",
        "Exfiltration", "Impact", "Initial Access", "Lateral Movement",
        "Persistence", "Privilege Escalation", "Collection", "Command and Control",
    ]
    tactics_lower = {t.lower(): t for t in tactics}
    for part in parts:
        key = part.strip().lower()
        if key in tactics_lower:
            return tactics_lower[key]
    return "unknown"


def extract_technique_ids(tags):
    if not tags:
        return []
    ids = []
    for tag in tags:
        m = re.search(r"attack\.(t\d{4}(?:\.\d{3})?)", str(tag).lower())
        if m:
            ids.append(m.group(1).upper())
    return list(set(ids))


# ─── Load compiled ruleset metadata if possible ──────────────────────────
print("[*] Loading ruleset metadata...")
if os.path.isfile(RULESET_PATH):
    try:
        with open(RULESET_PATH, "r") as f:
            compiled_rules = json.load(f)
            print(f"[*] {len(compiled_rules)} rules loaded from compiled ruleset.")
    except Exception:
        print("[!] Could not parse compiled ruleset as JSON.")
else:
    print(f"[*] Ruleset source: {RULESET_PATH}")

# ─── Index original SigmaHQ YAML rules ──────────────────────────────────
print("[*] Indexing SigmaHQ YAML rules...")
sigma_yaml_index = {}

# Match both .yml and .yaml extensions
yaml_files = glob.glob(f"{SIGMA_RULES_DIR}/**/*.yml", recursive=True) + \
             glob.glob(f"{SIGMA_RULES_DIR}/**/*.yaml", recursive=True)

for yf in yaml_files:
    try:
        with open(yf, "r", encoding="utf-8", errors="ignore") as f:
            docs = list(yaml.safe_load_all(f))
            if not docs:
                continue
            content = docs[0]
        if content and isinstance(content, dict) and ("title" in content or "id" in content):
            meta = {
                "path": os.path.relpath(yf, os.getcwd()),
                "references":  content.get("references", []) or [],
                "tags":        content.get("tags", []) or [],
                "description": content.get("description", ""),
                "level":       content.get("level", ""),
                "status":      content.get("status", ""),
                "logsource":   content.get("logsource", {}),
                "author":      content.get("author", ""),
                "id":          content.get("id", ""),
                "title":       content.get("title", ""),
            }
            # Index by both ID and Title for better matching
            if meta["id"]:
                sigma_yaml_index[meta["id"]] = meta
            if meta["title"]:
                sigma_yaml_index[meta["title"].strip()] = meta
    except Exception:
        continue

print(f"[*] {len(sigma_yaml_index)} rule identifiers (IDs/titles) indexed from {len(yaml_files)} files.")

# ─── Process Zircolite results ───────────────────────────────────────────
print("[*] Processing Zircolite results...")

triplets = []
stats = defaultdict(int)

result_files = sorted(glob.glob(f"{RAW_DIR}/*.json"))

for rf in result_files:
    try:
        with open(rf, "r") as f:
            detections = json.load(f)
    except Exception:
        stats["parse_errors"] += 1
        continue

    if not detections or not isinstance(detections, list) or len(detections) == 0:
        stats["empty_results"] += 1
        continue

    # Reconstruct relative EVTX path from safe filename
    safe_name = os.path.basename(rf).replace(".json", "")
    evtx_relative = safe_name.replace("__", "/") + ".evtx"
    tactic = infer_tactic_from_path(evtx_relative)

    for detection in detections:
        stats["total_detections"] += 1

        # ── Extract fields (Zircolite output format) ──
        rule_title  = detection.get("title", "")
        rule_level  = detection.get("rule_level", detection.get("level", ""))
        sigma_tags  = detection.get("tags", [])
        sigma_id    = detection.get("sigma_id", detection.get("id", ""))
        matched_evts = detection.get("matches", [])
        count       = detection.get("count", len(matched_evts) if isinstance(matched_evts, list) else 0)

        technique_ids = extract_technique_ids(sigma_tags)

        # ── Cross-reference with original YAML ──
        # Try matching by ID first (more reliable), then by title
        yaml_meta = sigma_yaml_index.get(sigma_id, sigma_yaml_index.get(rule_title.strip(), {}))
        references = yaml_meta.get("references", []) if yaml_meta else []

        cti_references = []
        for ref in references:
            cls = classify_reference(str(ref))
            if cls in ("cti", "likely_cti"):
                cti_references.append({"url": ref, "classification": cls})

        triplet = {
            "evtx_file":           evtx_relative,
            "evtx_tactic_folder":  tactic,
            "sigma_rule": {
                "title":       rule_title,
                "id":          yaml_meta.get("id", sigma_id),
                "level":       yaml_meta.get("level", rule_level),
                "status":      yaml_meta.get("status", ""),
                "description": yaml_meta.get("description", ""),
                "author":      yaml_meta.get("author", ""),
                "tags":        sigma_tags if isinstance(sigma_tags, list) else [],
                "logsource":   yaml_meta.get("logsource", {}),
                "yaml_path":   yaml_meta.get("path", ""),
            },
            "technique_ids":       technique_ids,
            "all_references":      references,
            "cti_references":      cti_references,
            "matched_event_count": count,
            "has_cti_link":        len(cti_references) > 0,
        }
        triplets.append(triplet)

        if cti_references:
            stats["triplets_with_cti"] += 1
        else:
            stats["triplets_without_cti"] += 1

# ─── Save outputs ─────────────────────────────────────────────────────────
TRIPLET_DIR = f"{OUTPUT_DIR}/triplets"
os.makedirs(TRIPLET_DIR, exist_ok=True)

# Full dataset
with open(f"{TRIPLET_DIR}/full_dataset.json", "w") as f:
    json.dump(triplets, f, indent=2, default=str)

# CTI-linked subset
cti_triplets = [t for t in triplets if t["has_cti_link"]]
with open(f"{TRIPLET_DIR}/cti_linked_dataset.json", "w") as f:
    json.dump(cti_triplets, f, indent=2, default=str)

# Unique CTI URLs
all_cti_urls = set()
for t in cti_triplets:
    for ref in t["cti_references"]:
        all_cti_urls.add(ref["url"])
with open(f"{TRIPLET_DIR}/unique_cti_urls.txt", "w") as f:
    for url in sorted(all_cti_urls):
        f.write(url + "\n")

# Per-technique summary
tech_summary = defaultdict(lambda: {"count": 0, "with_cti": 0, "rules": set(), "evtx_files": set()})
for t in triplets:
    for tid in t["technique_ids"]:
        tech_summary[tid]["count"] += 1
        tech_summary[tid]["rules"].add(t["sigma_rule"]["title"])
        tech_summary[tid]["evtx_files"].add(t["evtx_file"])
        if t["has_cti_link"]:
            tech_summary[tid]["with_cti"] += 1

tech_out = {}
for tid, d in sorted(tech_summary.items()):
    tech_out[tid] = {
        "total_matches":    d["count"],
        "matches_with_cti": d["with_cti"],
        "unique_rules":     sorted(list(d["rules"])),
        "unique_evtx_files": sorted(list(d["evtx_files"])),
    }
with open(f"{TRIPLET_DIR}/technique_summary.json", "w") as f:
    json.dump(tech_out, f, indent=2)

# ─── Print summary ────────────────────────────────────────────────────────
print("\n" + "=" * 60)
print("  DATASET BUILD SUMMARY")
print("=" * 60)
print(f"  EVTX result files processed:   {len(result_files)}")
print(f"  Files with detections:         {len(result_files) - stats['empty_results']}")
print(f"  Total rule matches (raw):      {stats['total_detections']}")
print(f"  Triplets WITH CTI refs:        {stats['triplets_with_cti']}")
print(f"  Triplets WITHOUT CTI refs:     {stats['triplets_without_cti']}")
print(f"  Parse errors:                  {stats['parse_errors']}")
print(f"  Unique techniques:             {len(tech_out)}")
print(f"  Unique CTI URLs:               {len(all_cti_urls)}")
print("=" * 60)

print(f"\n[✓] full_dataset.json          → {len(triplets)} triplets")
print(f"[✓] cti_linked_dataset.json    → {len(cti_triplets)} triplets")
print(f"[✓] unique_cti_urls.txt        → {len(all_cti_urls)} URLs")
print(f"[✓] technique_summary.json     → {len(tech_out)} techniques")

if tech_out:
    print("\n  TOP 15 TECHNIQUES:")
    print("  " + "-" * 58)
    sorted_t = sorted(tech_out.items(), key=lambda x: x[1]["total_matches"], reverse=True)[:15]
    for tid, d in sorted_t:
        cti = "✓" if d["matches_with_cti"] > 0 else "✗"
        print(f"  {tid:12s} | {d['total_matches']:4d} matches | {d['matches_with_cti']:3d} w/CTI | {cti}")

PYTHON_SCRIPT

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: DONE
# ─────────────────────────────────────────────────────────────────────────────
log_step "Pipeline Complete"

echo ""
echo "📁 Output tree:"
echo "  output/"
echo "    ├── raw_matches/              (per-EVTX Zircolite JSON results)"
echo "    ├── triplets/"
echo "    │   ├── full_dataset.json     (ALL log↔rule matches)"
echo "    │   ├── cti_linked_dataset.json (only matches with CTI refs)"
echo "    │   ├── unique_cti_urls.txt   (CTI URLs for manual review)"
echo "    │   └── technique_summary.json"
echo "    └── logs/                     (Zircolite stderr logs)"
echo ""
echo "Next steps:"
echo "  1. Review unique_cti_urls.txt"
echo "  2. Manually verify 20-30 triplets for gold standard"
echo "  3. Fetch CTI content: python3 fetch_cti_content.py --urls output/triplets/unique_cti_urls.txt --output output/cti_content/"
echo ""