#!/usr/bin/env bash
# End-to-end check of the calendar, reminders, clipboard and screen-context tools, the permission gate, spoken replies and the
# first-run walkthrough, through the real Debug app and the local mock model server.
#
#   scripts/build.sh                 # build the Debug app first
#   scripts/e2e-tools.sh             # then run this
#
# The tools run against made-up sample data (VOXA_DEBUG_SAMPLE_DATA), and permission answers are scripted
# (VOXA_DEBUG_TOOL_PERMISSIONS), so nothing here touches a real calendar, a real clipboard or System Settings, and no system
# prompt appears. One check does speak a short sentence aloud, to prove the voice works on this Mac.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/e2e.sh"

GRANTED="calendars=granted,reminders=granted"
# One command per conversation: what a tool reads would otherwise make the next command ask, which is right, but not what is
# being checked here.
FRESH='"followUpWindowSeconds":0'
QUIET='"speakReplies":false'

settings() { write_settings "{\"localeIdentifier\":\"en_US\",\"onboardingCompleted\":true,$FRESH,$QUIET$1}"; }

reply_has() { audit_reply "$MARK" | grep -qi "$1"; }

# ---------------------------------------------------------------------------------------------------------------------------
e2e_init

log "Calendar, reminders, clipboard and screen context, against sample data"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"

ask "calendar today"
check "reading the calendar just runs (read-only, no question)" "$(audit_has "$MARK" policyDecision calendar_list_events allow && echo 0 || echo 1)"
check "the command completes with the events in the reply" "$(audit_has "$MARK" reply && reply_has "Dentist" && echo 0 || echo 1)"

ask "add lunch"
check "adding an event runs with a notice, without asking" "$(audit_has "$MARK" policyDecision calendar_create_event notice && ! audit_has "$MARK" confirmation && echo 0 || echo 1)"
check "the reply says it was added" "$(reply_has "Added lunch" && echo 0 || echo 1)"

ask "move dentist"
check "changing an event always asks" "$(audit_has "$MARK" policyDecision calendar_update_event confirm && echo 0 || echo 1)"
answer allow
check "once allowed, the event is moved" "$(audit_has "$MARK" toolResult calendar_update_event ok && reply_has "moved" && echo 0 || echo 1)"

ask "delete dentist"
check "deleting an event always asks" "$(audit_has "$MARK" policyDecision calendar_delete_event confirm && echo 0 || echo 1)"
answer deny
check "declined, nothing is deleted and the command says so" "$(! audit_has "$MARK" toolResult calendar_delete_event ok && reply_has "left it alone" && echo 0 || echo 1)"

ask "remind me"
check "adding a reminder runs with a notice" "$(audit_has "$MARK" policyDecision reminders_create notice && reply_has "remind you" && echo 0 || echo 1)"
ask "list reminders"
check "reading reminders just runs" "$(audit_has "$MARK" policyDecision reminders_list allow && audit_has "$MARK" reply && echo 0 || echo 1)"

ask "read clipboard"
check "reading the clipboard runs with a notice, and returns what is on it" "$(audit_has "$MARK" policyDecision clipboard_read notice && reply_has "Call Sam" && echo 0 || echo 1)"
ask "copy hello"
check "copying to the clipboard runs with a notice" "$(audit_has "$MARK" policyDecision clipboard_write notice && reply_has "Copied" && echo 0 || echo 1)"
ask "frontmost"
check "checking the front app just runs, and names it" "$(audit_has "$MARK" policyDecision get_frontmost_context allow && reply_has "Safari" && echo 0 || echo 1)"

check "every request the app made was a valid one" "$(requests_valid anthropic && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "An invitation with an instruction hidden in its title"
launch --env VOXA_DEBUG_SAMPLE_DATA=hostile --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"
ask "calendar inject"
check "the fooled model's request to open a link is stopped and put to the user" "$(audit_has "$MARK" policyDecision open_url confirm && echo 0 || echo 1)"
answer deny
check "declined, the link is never opened" "$(! audit_has "$MARK" toolResult open_url ok && reply_has "didn't open" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "The permission gate"
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=calendars=denied,reminders=granted"
ask "calendar today"
check "a refused permission ends the command with an error, and the tool never runs" \
    "$(audit_has "$MARK" permission calendar_list_events denied && audit_has "$MARK" failure && ! audit_has "$MARK" toolResult calendar_list_events && echo 0 || echo 1)"
check "the status shows the error" "$(report_has "status=error" && echo 0 || echo 1)"
ask "remind me"
check "a permission that is granted is unaffected" "$(audit_has "$MARK" toolResult reminders_create ok && echo 0 || echo 1)"

launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=calendars=notDetermined,reminders=granted"
ask "calendar today"
check "a permission not yet asked about is asked for, and the command carries on once it is given" "$(audit_has "$MARK" toolResult calendar_list_events ok && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "Spoken replies"
write_settings '{"localeIdentifier":"en_US","onboardingCompleted":true,"speakReplies":true,"followUpWindowSeconds":0}'
launch
printf 'Testing one two.' >"$WORK/say.txt"
notifyutil -p com.rohitsainier.voxa.debug.say
check "the voice starts speaking" "$(wait_for 5 report_has "speaking=true" && echo 0 || echo 1)"
check "and finishes on its own" "$(wait_for 15 report_has "speaking=false" && echo 0 || echo 1)"

# A whole command whose reply is spoken, cut off by Esc while the reply is up. (The shortcut itself is not pressed here: with
# the microphone not yet allowed to this build, that would bring up the system's permission prompt.)
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"
ask "add lunch"
check "the reply is spoken as well as shown" "$(wait_for 5 report_has "speaking=true" && echo 0 || echo 1)"
notifyutil -p com.rohitsainier.voxa.debug.key.escape
check "Esc cuts the speech off at once" "$(wait_for 3 report_has "speaking=false" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "The first-run walkthrough"
write_settings '{"localeIdentifier":"en_US","onboardingCompleted":false,"speakReplies":false}'
launch
check "a first run opens the walkthrough by itself" "$(report_has "welcome=true" && echo 0 || echo 1)"
notifyutil -p com.rohitsainier.voxa.debug.onboarding.close
check "and it can be closed" "$(wait_for 3 report_has "welcome=false" && echo 0 || echo 1)"

write_settings '{"localeIdentifier":"en_US","onboardingCompleted":true,"speakReplies":false}'
launch
check "once finished, the walkthrough does not open by itself again" "$(report_has "welcome=false" && echo 0 || echo 1)"
notifyutil -p com.rohitsainier.voxa.debug.onboarding
check "but it can be opened again on request" "$(wait_for 3 report_has "welcome=true" && echo 0 || echo 1)"
notifyutil -p com.rohitsainier.voxa.debug.onboarding.close
wait_for 3 report_has "welcome=false" || true
notifyutil -p com.rohitsainier.voxa.debug.button.welcomeGuide
check "and so can it from the button in Settings" "$(wait_for 3 report_has "welcome=true" && echo 0 || echo 1)"

log "The Settings tabs"
for tab in general model tools permissions safety history; do
    notifyutil -p "com.rohitsainier.voxa.debug.settings.tab.$tab"
    check "Settings opens on the $tab tab" "$(wait_for 3 report_has "settingsTab=$tab" && echo 0 || echo 1)"
done

e2e_finish
