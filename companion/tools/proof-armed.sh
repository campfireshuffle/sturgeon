#!/bin/zsh
# proof-armed.sh — the armed-window proof for Sturgeon, driven through the app's own controls.
#
#   ./proof-armed.sh <app-pid>
#
# Assumes: the caller holds work/.wmtest.lock, the tool is currently DISARMED, and the Sturgeon
# popover is open.  It then does, in order:
#
#   1. screenshot of the DISARMED popover
#   2. AX press Start  -> wait for ARMED -> screenshot
#   3. cfg before / press "births" off / cfg after / press "births" on / cfg after
#   4. AX set the size slider to 1.3 -> wait for the resize result -> measure -> screenshot
#   5. AX press "Reset to 100%" -> measure -> screenshot
#   6. AX press Stop -> wait for DISARMED -> screenshot
#
# Everything it prints is appended to proof-notes.txt in the output directory.  It never clicks
# the mouse: all control is AXPress / AXValue on the app itself, and the resize sweep is the
# shipped `wmship.sh resize` command the app invokes.
set -u
W=${0:A:h:h:h}
OUT=$W/re/round35-sturgeon
AX=$W/companion/tools/axui
PID=${1:?usage: proof-armed.sh <app-pid>}
mkdir -p $OUT
NOTES=$OUT/proof-notes.txt
: > $NOTES

say() { print -r -- "$*" | tee -a $NOTES }
axget() { $AX $PID get "$1" 2>/dev/null | sed -n 's/.* value=//p' | sed 's/ enabled=.*//' }
shot() {
  local name=$1
  local f=($($AX $PID popover))
  if [ ${#f} -eq 4 ]; then
    screencapture -x -R "$((f[1]-8)),$((f[2]-8)),$((f[3]+16)),$((f[4]+16))" $OUT/$name.png
  else
    screencapture -x $OUT/$name.png
  fi
  say "shot: $OUT/$name.png"
}
wait_value() { # identifier pattern timeout_s
  local id=$1 pat=$2 t=${3:-90} i=0
  while (( i < t * 2 )); do
    local v=$(axget $id)
    if [[ $v == *$pat* ]]; then print -r -- "$v"; return 0; fi
    sleep 0.5; (( i++ ))
  done
  return 1
}

cd $W
say "=== proof started $(date) pid=$PID ==="
say "--- status before"
./wmship.sh status 2>&1 | tee -a $NOTES

# 1 ------------------------------------------------------------------ disarmed
say "--- state badge: $(axget stateBadge)"
shot b1-disarmed

# 2 ------------------------------------------------------------------ start
say "--- AX press Start"
$AX $PID press startButton | tee -a $NOTES
if wait_value stateBadge ARMED 180 >/dev/null; then
  say "armed: $(axget stateBadge)"
else
  say "ERROR: app never reported ARMED"; fi
sleep 2
say "--- app footer: $(axget footerLine)"
say "--- doctor: $(axget doctorVerdict)"
shot b2-armed
say "--- status while armed"
./wmship.sh status 2>&1 | tee -a $NOTES

# 3 ------------------------------------------------------------------ births
say "--- cfg BEFORE (./wmship.sh cfg)"
./wmship.sh cfg 2>&1 | tee $OUT/c-cfg-before.json
say "--- AX press birthsToggle (off)"
$AX $PID press birthsToggle | tee -a $NOTES
sleep 2
say "--- app footer: $(axget footerLine)"
./wmship.sh cfg 2>&1 | tee $OUT/c-cfg-off.json
say "--- AX press birthsToggle (on)"
$AX $PID press birthsToggle | tee -a $NOTES
sleep 2
say "--- app footer: $(axget footerLine)"
./wmship.sh cfg 2>&1 | tee $OUT/c-cfg-on.json

# 4 ------------------------------------------------------------------ slider 1.3
say "--- AX set scaleSlider 1.30"
$AX $PID set scaleSlider 1.3 | tee -a $NOTES
if wait_value footerLine "resize 1.30" 180 >/dev/null; then
  say "resize result: $(axget footerLine)"
else
  say "ERROR: no resize result in the footer; last: $(axget footerLine)"
fi
sleep 1
say "--- app slider readout: $(axget scaleReadout)"
shot d1-scale-130
say "--- measure after 1.3"
./wmship.sh measure 2>&1 | tee $OUT/d-measure-130.json

# 5 ------------------------------------------------------------------ reset
say "--- AX press Reset to 100%"
$AX $PID press resetButton | tee -a $NOTES
if wait_value footerLine "resize 1.00" 180 >/dev/null; then
  say "reset result: $(axget footerLine)"
else
  say "ERROR: no reset result in the footer; last: $(axget footerLine)"
fi
sleep 1
say "--- app slider readout: $(axget scaleReadout)"
shot d2-scale-100
say "--- measure after reset"
./wmship.sh measure 2>&1 | tee $OUT/d-measure-100.json

# 6 ------------------------------------------------------------------ stop
say "--- AX press Stop"
$AX $PID press stopButton | tee -a $NOTES
if wait_value stateBadge DISARMED 240 >/dev/null; then
  say "disarmed: $(axget stateBadge)"
else
  say "ERROR: app never reported DISARMED"; fi
sleep 2
say "--- app footer: $(axget footerLine)"
shot e1-disarmed-after-stop
say "--- status after stop"
./wmship.sh status 2>&1 | tee $OUT/e-status-after-stop.txt
say "--- pristine"
./wmship.sh pristine 2>&1 | tee $OUT/e-pristine.txt
say "=== proof finished $(date) ==="
