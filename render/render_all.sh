#!/bin/bash
# Renders every scene that exists, in display order, as the four contract
# variants into ../Relaxios/Videos/, then checks each file with check_video.py
# and avcheck. Exit status is non-zero if any render or check failed.
#
# usage: ./render_all.sh [scene ...]          (default: window plains sea above)
# env:   OUT=<dir>        output folder (default ../Relaxios/Videos)
#        ONLY=<pattern>   only variants whose "<orient>_<res>" matches, e.g. ONLY=720, ONLY=portrait_1080
#        DRY=1            print the commands, render nothing
#
# Per-scene overrides live in scenes/<id>.conf (sourced as bash), any of:
#   SS=2  XFADE=0  SEED=1  LOOP=40  FPS=30
#   CRF=  CRF_1080=  CRF_720=  PRESET=  MAXRATE_1080=  MAXRATE_720=
#   EXTRA=(--define FOO=1)        extra storm-render args
#   CHECK=(--max-jump 0.12)       extra check_video.py args
# Empty values fall back to the storm-render / check_video.py defaults.

cd "$(dirname "$0")" || exit 1
OUT=${OUT:-../Relaxios/Videos}
SCENES=(window plains sea above)
[ $# -gt 0 ] && SCENES=("$@")

[ -x bin/storm-render ] && [ -x bin/avcheck ] || ./build.sh || exit 1
mkdir -p "$OUT"

run() {
    echo "+ $*"
    [ -n "$DRY" ] || "$@"
}

tmp=""
# Videos/ is an Xcode folder reference: never leave a partial render in it.
trap '[ -n "$tmp" ] && rm -f "$tmp"; exit 130' INT TERM

failed=()
done_files=()
start=$(date +%s)

for id in "${SCENES[@]}"; do
    if [ ! -f "scenes/$id.metal" ]; then
        echo "skip $id: no scenes/$id.metal"
        continue
    fi
    SS=2 XFADE=0 SEED=1 LOOP=40 FPS=30
    CRF="" CRF_1080="" CRF_720="" PRESET="" MAXRATE_1080="" MAXRATE_720=""
    EXTRA=() CHECK=()
    # shellcheck disable=SC1090
    [ -f "scenes/$id.conf" ] && source "scenes/$id.conf"
    frames=$(awk "BEGIN { printf \"%d\", $LOOP * $FPS + 0.5 }")

    for orient in portrait landscape; do
        for res in 1080 720; do
            variant="${orient}_${res}"
            case "$variant" in *"${ONLY:-}"*) ;; *) continue ;; esac
            if [ "$res" = 1080 ]; then long=1920 short=1080; crf=${CRF_1080:-$CRF}; maxrate=$MAXRATE_1080
            else long=1280 short=720; crf=${CRF_720:-$CRF}; maxrate=$MAXRATE_720; fi
            if [ "$orient" = portrait ]; then w=$short h=$long; else w=$long h=$short; fi

            file="$OUT/${id}_${variant}.mp4"
            tmp="$OUT/.${id}_${variant}.tmp.mp4"
            args=(--scene "$id" --w "$w" --h "$h" --ss "$SS" --xfade "$XFADE" --seed "$SEED" --loop "$LOOP" --fps "$FPS")
            [ -n "$crf" ] && args+=(--crf "$crf")
            [ -n "$PRESET" ] && args+=(--preset "$PRESET")
            [ -n "$maxrate" ] && args+=(--maxrate "$maxrate")
            args+=("${EXTRA[@]}")

            echo "=== $id $variant (${w}x${h})"
            if ! run ./bin/storm-render "${args[@]}" --video "$tmp"; then
                failed+=("$id $variant: render")
                rm -f "$tmp"
                continue
            fi
            [ -n "$DRY" ] || mv -f "$tmp" "$file"
            done_files+=("$file")
            run python3 tools/check_video.py "$file" --fps "$FPS" --frames "$frames" "${CHECK[@]}" || failed+=("$id $variant: check_video")
            run ./bin/avcheck "$file" --w "$w" --h "$h" || failed+=("$id $variant: avcheck")
        done
    done
done

echo
echo "rendered ${#done_files[@]} file(s) in $(( $(date +%s) - start ))s into $OUT"
for f in "${done_files[@]}"; do
    [ -f "$f" ] && printf '  %-40s %6.2f MB\n' "$(basename "$f")" "$(echo "$(stat -f %z "$f") / 1000000" | bc -l)"
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
echo "all passed"
