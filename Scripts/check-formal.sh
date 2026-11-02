#!/bin/bash
# Model-check every formal/<Spec>.tla with pinned TLC.
# - formal/<Spec>.cfg must pass: these rules hold for the current code.
# - formal/mutants/<Spec>/*.cfg must fail the rule named on their `\* expect: Rule` line.
# - formal/findings/<Spec>/*.cfg reproduce open findings; same `expect` line plus `\* issue: URL`.
#   A finding that stops failing means the code changed: move its rule into <Spec>.cfg.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in java curl shasum; do
    command -v "$tool" >/dev/null || { echo "check-formal requires $tool on PATH" >&2; exit 1; }
done
java_version="$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\)\.\{0,1\}\([0-9]*\).*/\1 \2/p' | head -1)"
read -r java_major java_minor <<<"$java_version"
# Java 8 and older report "1.x".
[[ "${java_major:-0}" == 1 ]] && java_major="${java_minor:-0}"
(( ${java_major:-0} >= 11 )) || { echo "check-formal requires Java 11 or newer; found: ${java_version:-unknown}" >&2; exit 1; }
tools="$PWD/.build/formal-tools"
jar="$tools/tla2tools-1.7.4.jar"
checksum=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
if [[ ! -f "$jar" ]] || ! echo "$checksum  $jar" | shasum -a 256 -c - >/dev/null 2>&1; then
    mkdir -p "$tools"
    curl --fail --location --retry 3 --silent --show-error \
        https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar --output "$jar.download"
    echo "$checksum  $jar.download" | shasum -a 256 -c - >/dev/null
    mv "$jar.download" "$jar"
fi
logs="$PWD/.build/formal"
rm -rf "$logs"
mkdir -p "$logs"
only="${1:-}"
failed=0

tlc() {
    local spec="$1" config="$2" name
    name="$spec"
    [[ "$config" == */* ]] && name="$spec-$(basename "$(dirname "$(dirname "$config")")")-$(basename "$config" .cfg)"
    (cd formal && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -cleanup \
        -metadir "$logs/$name.states" -config "$config" "$spec.tla") > "$logs/$name.log" 2>&1 || true
    echo "$logs/$name.log"
}

expected_rule() { sed -n 's/^\\\* expect: *//p' "$1"; }

for model in formal/*.tla; do
    spec="$(basename "$model" .tla)"
    [[ -z "$only" || "$only" == "$spec" ]] || continue
    log="$(tlc "$spec" "$spec.cfg")"
    if grep -q 'Model checking completed. No error has been found.' "$log"; then
        echo "PASS $spec ($(grep -Eo '[0-9]+ distinct states found' "$log" | tail -1))"
    else
        echo "FAIL $spec: a rule that held now breaks. Full trace: $log" >&2
        grep -E '^Error' "$log" >&2 || tail -20 "$log" >&2
        failed=1
    fi
    for config in formal/mutants/"$spec"/*.cfg formal/findings/"$spec"/*.cfg; do
        [[ -f "$config" ]] || continue
        rule="$(expected_rule "$config")" kind="$(basename "$(dirname "$(dirname "$config")")")"
        log="$(tlc "$spec" "${config#formal/}")"
        if grep -q "Invariant $rule is violated" "$log"; then
            if [[ "$kind" == findings ]]; then
                echo "OPEN $spec finding $(basename "$config" .cfg) breaks $rule ($(sed -n 's/^\\\* issue: *//p' "$config"))"
            else
                echo "PASS $spec mutant $(basename "$config" .cfg) fails $rule"
            fi
        else
            echo "FAIL $spec $kind $(basename "$config" .cfg) no longer breaks $rule. Output: $log" >&2
            failed=1
        fi
    done
done
exit "$failed"
