#!/usr/bin/env bash
# End-to-end check of the Voxa bar (a field to type a command in, and a microphone button that listens continuously) through the real
# Debug app and the local mock model server.
#
#   DERIVED_DATA=/private/tmp/voxa-e2e-build scripts/build.sh    # build the Debug app first, somewhere of your own
#   DERIVED_DATA=/private/tmp/voxa-e2e-build scripts/e2e-bar.sh  # then run this
#
# No microphone and no person are involved. The bar is worked through the app's debug hooks (open it, type into it, press its
# microphone). Continuous listening hears a clip made with `say` that the app plays in place of the microphone
# (VOXA_DEBUG_HANDSFREE_AUDIO, once, in real time), so the real voice-activity detector, listener and session run; what the speech
# recognizer "hears" for each utterance is scripted (VOXA_DEBUG_HANDSFREE_TRANSCRIPTS), because the speech engines need a permission a
# script can't be granted. Commands run against made-up sample data. `say` writes to files here, so nothing is spoken aloud.
# The app under test is a private copy (see scripts/lib/e2e.sh), so a Voxa someone is running is never touched.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/e2e.sh"

require say "say is part of macOS"
require afconvert "afconvert is part of macOS"

GRANTED="calendars=granted,reminders=granted"
QUIET='"speakReplies":false'
# One command per conversation: what a tool reads would otherwise make the next command ask, which is right, but not what is being
# checked here.
FRESH='"followUpWindowSeconds":0'
settings() { write_settings "{\"localeIdentifier\":\"en_US\",\"onboardingCompleted\":true,$FRESH,$QUIET$1}"; }

reply_has() { audit_reply "$MARK" | grep -qi "$1"; }
state_is() { report | grep -q "handsFree=$1"; }
bar_is() { report | grep -q "bar=$1"; }
report_field() { report | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2; }
# What the bar is showing below its field: idle, listening, thinking, acting, confirm, reply, ...
bar_mode() { [[ "$(report_field barMode)" == "$1" ]]; }

# clip <name> <lead seconds> <phrase:gap seconds>...: a 16 kHz clip that is silent for <lead> seconds and then says each phrase in turn,
# with that many seconds of silence after it. `say` writes the speech to a file; the clip is stitched together here.
clip() {
    local name="$1" lead="$2"; shift 2
    local parts=()
    local index=0
    for item in "$@"; do
        local phrase="${item%%:*}"
        say -v Samantha -o "$WORK/say$index.aiff" "$phrase"
        afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/say$index.aiff" "$WORK/say$index.wav"
        parts+=("$WORK/say$index.wav:${item##*:}")
        index=$((index + 1))
    done
    python3 - "$WORK/$name.wav" "$lead" "${parts[@]}" <<'PY'
import sys, wave
out, lead, parts = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
frames = b"\x00\x00" * int(16000 * lead)
for part in parts:
    path, gap = part.rsplit(":", 1)
    with wave.open(path) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        frames += w.readframes(w.getnframes())
    frames += b"\x00\x00" * int(16000 * float(gap))
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(frames)
PY
}

# type <text>: types it into the bar and presses Return (opening the bar if it isn't open).
type_in_bar() { printf '%s' "$1" >"$WORK/command.txt"; hook bar.type; }

# ---------------------------------------------------------------------------------------------------------------------------
e2e_init

log "Typing a command into the bar"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"
check "the bar starts out of the way, and the microphone off" "$(bar_is hidden && state_is off && echo 0 || echo 1)"

hook bar.show
check "opening it shows it, ready for typing (it is the key window)" "$(wait_for 5 bar_is visible && [[ "$(report_field barKey)" == "true" ]] && echo 0 || echo 1)"

MARK="$(audit_lines)"
type_in_bar "calendar today"
check "a typed command runs like a spoken one" "$(wait_for 30 finished && audit_has "$MARK" command && audit_has "$MARK" policyDecision calendar_list_events allow && reply_has "Dentist" && echo 0 || echo 1)"
check "the reply appears in the bar itself, not in a window of its own" "$(wait_for 5 bar_mode reply && bar_is visible && echo 0 || echo 1)"
check "the bar has given the keyboard back (a command may type in the app in front) and takes neither typing nor clicks while it only shows the command" "$([[ "$(report_field barKey)" == "false" && "$(report_field barCanKey)" == "false" && "$(report_field barClicks)" == "false" && "$(report_field barText)" == "empty" && "$(report_field barOpen)" == "false" ]] && echo 0 || echo 1)"
check "and it goes by itself once the reply has been shown" "$(wait_for 40 bar_is hidden && echo 0 || echo 1)"

hook bar.show
check "opened again it has the keyboard" "$(wait_for 5 bar_is visible && [[ "$(report_field barKey)" == "true" ]] && echo 0 || echo 1)"
hook bar.hide
check "Esc puts the bar away" "$(bar_is hidden && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "A command typed while another waits for an answer is not taken"
MARK="$(audit_lines)"
type_in_bar "delete dentist"
check "a command that needs approval asks, whoever typed it" "$(wait_for 30 is_asking && audit_has "$MARK" policyDecision calendar_delete_event confirm && echo 0 || echo 1)"
check "the question is in the bar itself: it can be clicked, and it cannot take the keyboard" "$(bar_is visible && bar_mode confirm && [[ "$(report_field barClicks)" == "true" && "$(report_field barCanKey)" == "false" && "$(report_field barKey)" == "false" ]] && echo 0 || echo 1)"
type_in_bar "calendar today"
check "a second command stays in the field with the bar telling why, and nothing new is run" "$([[ "$(report_field barText)" == "typed" && "$(report_field barNote)" == "shown" ]] && is_asking && echo 0 || echo 1)"
answer deny
check "the person's own answer still works" "$(! audit_has "$MARK" toolResult calendar_delete_event ok && reply_has "left it alone" && echo 0 || echo 1)"
hook bar.hide

# ---------------------------------------------------------------------------------------------------------------------------
log "The microphone button: listening continuously, with no wake phrase"
clip two 2.5 "calendar today:2.5" "read clipboard:3"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED" --env "VOXA_DEBUG_HANDSFREE_AUDIO=$WORK/two.wav" \
    --env "VOXA_DEBUG_HANDSFREE_TRANSCRIPTS=calendar today|read clipboard"
sleep 4
check "with the microphone button not pressed nothing listens, and nothing runs, however long" "$(state_is off && [[ "$(audit_lines)" == "0" ]] && echo 0 || echo 1)"

MARK="$(audit_lines)"
hook bar.show
hook bar.mic
check "clicking the microphone starts listening" "$(wait_for 10 state_is listening && echo 0 || echo 1)"
check "the first thing said runs as a command, with no wake phrase" "$(wait_for 40 audit_has "$MARK" policyDecision calendar_list_events allow && echo 0 || echo 1)"
check "while it works the microphone is let go of" "$(wait_for 15 state_is paused && echo 0 || echo 1)"
check "and the listening bar stays where it can be seen, but has given the keyboard back to the app in front" "$(bar_is visible && [[ "$(report_field barKey)" == "false" ]] && echo 0 || echo 1)"
check "and the next thing said runs too, so it listens continuously" "$(wait_for 60 audit_has "$MARK" policyDecision clipboard_read notice && echo 0 || echo 1)"
hook bar.mic
check "clicking the microphone again stops it" "$(wait_for 10 state_is off && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "Putting the bar away stops the microphone"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED" --env "VOXA_DEBUG_HANDSFREE_AUDIO=$WORK/two.wav" \
    --env "VOXA_DEBUG_HANDSFREE_TRANSCRIPTS=calendar today|read clipboard"
hook bar.show
hook bar.mic
check "it is listening" "$(wait_for 10 state_is listening && echo 0 || echo 1)"
hook bar.hide
check "Esc closes the bar and the microphone with it" "$(bar_is hidden && wait_for 10 state_is off && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "It is off again after a restart: listening is never a saved setting"
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED" --env "VOXA_DEBUG_HANDSFREE_AUDIO=$WORK/two.wav"
check "a fresh launch has the microphone off and the bar away" "$(state_is off && bar_is hidden && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "A voice cannot approve an action"
clip approve 2.5 "delete dentist:1.5" "yes allow it:4"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED" --env "VOXA_DEBUG_HANDSFREE_AUDIO=$WORK/approve.wav" \
    --env "VOXA_DEBUG_HANDSFREE_TRANSCRIPTS=delete dentist|yes allow it"
MARK="$(audit_lines)"
hook bar.show
hook bar.mic
check "a command that needs approval asks" "$(wait_for 40 is_asking && audit_has "$MARK" policyDecision calendar_delete_event confirm && echo 0 || echo 1)"
check "while the question is up the microphone is closed" "$(state_is paused.working && echo 0 || echo 1)"
sleep 12
check "nothing said can answer it: the question is still waiting and nothing was deleted" "$(is_asking && ! audit_has "$MARK" toolResult calendar_delete_event ok && echo 0 || echo 1)"
answer deny
check "the person's own answer still works" "$(! audit_has "$MARK" toolResult calendar_delete_event ok && reply_has "left it alone" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "A command handed over by Siri is a command like any other"
# The App Intent Siri runs calls SiriCommand; the debug hook calls the same function, so this checks the app's side of the hand-over
# (Siri's own listening can't be scripted).
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"
siri() { rm -f "$WORK/command.txt.siri"; printf '%s' "$1" >"$WORK/command.txt"; hook siri; wait_for 5 test -s "$WORK/command.txt.siri"; cat "$WORK/command.txt.siri" 2>/dev/null | tr -d '\n'; }

MARK="$(audit_lines)"
check "Voxa says it took the command" "$([[ "$(siri 'calendar today')" == "started" ]] && echo 0 || echo 1)"
check "and it runs like a spoken one" "$(wait_for 30 finished && audit_has "$MARK" policyDecision calendar_list_events allow && reply_has "Dentist" && echo 0 || echo 1)"

MARK="$(audit_lines)"
check "a command that needs approval still asks" "$([[ "$(siri 'delete dentist')" == "started" ]] && wait_for 30 is_asking && audit_has "$MARK" policyDecision calendar_delete_event confirm && echo 0 || echo 1)"
check "while it asks, a second command from Siri is turned away as busy" "$([[ "$(siri 'calendar today')" == "busy" ]] && echo 0 || echo 1)"
check "and 'yes' said to Siri does not answer the question" "$([[ "$(siri 'yes')" == "busy" ]] && is_asking && ! audit_has "$MARK" toolResult calendar_delete_event ok && echo 0 || echo 1)"
answer deny
check "the person's own answer still works" "$(! audit_has "$MARK" toolResult calendar_delete_event ok && reply_has "left it alone" && echo 0 || echo 1)"
check "an empty command is nothing to do" "$([[ "$(siri '   ')" == "nothing" ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "A microphone left on switches itself off after a silence"
settings ""
# Ten minutes would be a long wait: a Debug-only variable stands in for the setting with a few seconds.
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED" --env "VOXA_DEBUG_HANDSFREE_AUDIO=$WORK/two.wav" \
    --env VOXA_DEBUG_LISTENING_IDLE_SECONDS=12 --env "VOXA_DEBUG_HANDSFREE_TRANSCRIPTS=uh|uh|uh"
hook bar.show
hook bar.mic
check "it is listening" "$(wait_for 10 state_is listening && echo 0 || echo 1)"
# What the clip says is heard as "uh", which is not a command, so nothing is run and only the silence counts.
check "after a silence it lets go of the microphone by itself, and the bar says why" "$(wait_for 60 state_is off && [[ "$(report_field barNote)" == "shown" ]] && bar_is visible && echo 0 || echo 1)"

e2e_finish
