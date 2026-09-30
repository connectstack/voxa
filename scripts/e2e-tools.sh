#!/usr/bin/env bash
# End-to-end check of the calendar, reminders, clipboard and screen-context tools, the tools that read and drive other apps'
# windows, take screenshots and work with files, the permission gate, spoken replies and the first-run walkthrough, through the
# real Debug app and the local mock model server.
#
#   scripts/build.sh                 # build the Debug app first
#   scripts/e2e-tools.sh             # then run this
#
# The tools run against made-up sample data (VOXA_DEBUG_SAMPLE_DATA: a pretend Safari, a pretend disk), and permission answers are
# scripted (VOXA_DEBUG_TOOL_PERMISSIONS), so nothing here touches a real calendar, clipboard, window, screen or file, or System
# Settings, and no system prompt appears. One check does speak a short sentence aloud, to prove the voice works on this Mac.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/e2e.sh"

GRANTED="calendars=granted,reminders=granted"
ALL="$GRANTED,accessibility=granted,screenRecording=granted"
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
log "Other apps' windows, screenshots and files, against a pretend Safari and a pretend disk"
settings ""
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$ALL"

ask "ui inspect"
check "looking at the window just runs, and finds its controls" "$(audit_has "$MARK" policyDecision ui_inspect allow && reply_has "controls" && echo 0 || echo 1)"

ask "ui keys"
check "pressing a shortcut, with nothing outside read yet, runs with a notice and no question" \
    "$(audit_has "$MARK" policyDecision ui_press_keys notice && ! audit_has "$MARK" confirmation && reply_has "Pressed" && echo 0 || echo 1)"

ask "ui quit"
check "a shortcut that quits an app always asks" "$(audit_has "$MARK" policyDecision ui_press_keys confirm && echo 0 || echo 1)"
answer deny
check "declined, nothing is pressed" "$(! audit_has "$MARK" toolResult ui_press_keys ok && reply_has "didn't quit" && echo 0 || echo 1)"

ask "ui click reload"
check "a click after the window has been read asks, because what it read is outside content" "$(audit_has "$MARK" policyDecision ui_click confirm && echo 0 || echo 1)"
answer allow
check "once allowed, the button is pressed" "$(audit_has "$MARK" toolResult ui_click ok && reply_has "Clicked reload" && echo 0 || echo 1)"

ask "ui click feedback"
check "a button labelled Send Feedback asks, and says why" "$(audit_has "$MARK" policyDecision ui_click confirm && echo 0 || echo 1)"
answer deny
check "declined, it is not pressed" "$(! audit_has "$MARK" toolResult ui_click ok && reply_has "didn't" && echo 0 || echo 1)"

ask "ui type search"
check "typing after reading the window asks" "$(audit_has "$MARK" policyDecision ui_type confirm && echo 0 || echo 1)"
answer allow
check "once allowed, the text is typed" "$(audit_has "$MARK" toolResult ui_type ok && reply_has "Typed" && echo 0 || echo 1)"

ask "ui password"
check "typing into a password field is refused outright, with no question" \
    "$(audit_has "$MARK" policyDecision ui_type deny && ! audit_has "$MARK" confirmation && reply_has "password field" && echo 0 || echo 1)"

ask "shot window"
check "a picture of one window runs with a notice" "$(audit_has "$MARK" policyDecision screenshot notice && reply_has "took a look" && echo 0 || echo 1)"
ask "shot screen"
check "a picture of the whole screen always asks" "$(audit_has "$MARK" policyDecision screenshot confirm && echo 0 || echo 1)"
answer deny
check "declined, no picture is taken" "$(! audit_has "$MARK" toolResult screenshot ok && reply_has "didn't look" && echo 0 || echo 1)"
ask "shot click"
check "a click at a point in a picture asks" "$(audit_has "$MARK" policyDecision ui_click confirm && echo 0 || echo 1)"
answer allow
check "once allowed, the click lands on the button in the picture" "$(audit_has "$MARK" toolResult ui_click ok && reply_has "Clicked" && echo 0 || echo 1)"

ask "ui play"
check "the whole chain is one command: a wait just runs, the picture is taken with a notice, and the click asks (a picture is outside content)" \
    "$(audit_has "$MARK" policyDecision wait allow && audit_has "$MARK" toolResult wait ok && audit_has "$MARK" policyDecision screenshot notice && audit_has "$MARK" policyDecision ui_click confirm && echo 0 || echo 1)"
answer allow
check "once allowed, it clicks and says it is playing, without a second command" "$(audit_has "$MARK" toolResult ui_click ok && reply_has "Playing" && echo 0 || echo 1)"

ask "ui lazy"
check "a model that stops after its first step is checked, found unfinished, and sent back to work" \
    "$(audit_has "$MARK" completionCheck "" notDone && audit_has "$MARK" policyDecision screenshot notice && echo 0 || echo 1)"
answer allow
check "once allowed it finishes the job in the same command, and the second check says so" \
    "$(audit_has "$MARK" toolResult ui_click ok && audit_has "$MARK" completionCheck "" done && reply_has "Playing" && echo 0 || echo 1)"

ask "ui batch"
check "three calls sent together in one turn all run, in order, and the whole job took two requests: one step for the calls" \
    "$(audit_has "$MARK" toolResult wait ok && audit_has "$MARK" toolResult ui_inspect ok && audit_has "$MARK" toolResult ui_press_keys ok && reply_has "three things" && [[ "$(requests_for 'ui batch')" == "2" ]] && echo 0 || echo 1)"

ask "ui looked"
check "a model that looked at the result of what it did is not second-guessed: no check, and its reply stands" \
    "$(! audit_has "$MARK" completionCheck && audit_has "$MARK" toolResult screenshot ok && reply_has "Done" && echo 0 || echo 1)"

ask "find invoices"
check "searching for files just runs, and finds them" "$(audit_has "$MARK" policyDecision file_search allow && reply_has "april-invoice" && echo 0 || echo 1)"
ask "reveal report"
check "showing a file in Finder just runs" "$(audit_has "$MARK" policyDecision reveal_in_finder allow && reply_has "Showed" && echo 0 || echo 1)"
ask "move report"
check "moving a file always asks" "$(audit_has "$MARK" policyDecision file_move confirm && echo 0 || echo 1)"
answer deny
check "declined, the file stays where it is" "$(! audit_has "$MARK" toolResult file_move ok && reply_has "where it was" && echo 0 || echo 1)"
ask "trash screenshots"
check "trashing files always asks, after the search that found them" "$(audit_has "$MARK" policyDecision file_search allow && audit_has "$MARK" policyDecision file_trash confirm && echo 0 || echo 1)"
answer allow
check "once allowed, they go to the Trash" "$(audit_has "$MARK" toolResult file_trash ok && reply_has "Trash" && echo 0 || echo 1)"
ask "trash ssh"
check "a file in a hidden folder can never be trashed, and the user is not even asked" \
    "$(audit_has "$MARK" policyDecision file_trash deny && ! audit_has "$MARK" confirmation && reply_has "can't touch" && echo 0 || echo 1)"

check "every request the app made was a valid one" "$(requests_valid anthropic && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "Full control: what stops asking, and what never does"
settings ',"fullControl":true'
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$ALL"

ask "ui quit"
check "a shortcut that quits an app runs with no question, and the trail says it ran on the user's say-so" \
    "$(audit_has "$MARK" policyDecision ui_press_keys auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult ui_press_keys ok && echo 0 || echo 1)"

ask "ui click feedback"
check "a button labelled Send Feedback is pressed without asking" \
    "$(audit_has "$MARK" policyDecision ui_click auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult ui_click ok && echo 0 || echo 1)"

ask "ui type search"
check "typing after the window was read (outside content) no longer asks" \
    "$(audit_has "$MARK" policyDecision ui_type auto && ! audit_has "$MARK" confirmation && reply_has "Typed" && echo 0 || echo 1)"

ask "ui play"
check "the same chain under full control is one command with no question at all" \
    "$(audit_has "$MARK" toolResult wait ok && audit_has "$MARK" policyDecision ui_click auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult ui_click ok && reply_has "Playing" && echo 0 || echo 1)"

ask "ui lazy"
check "the checked, sent-back command finishes in one go under full control, with no question at all" \
    "$(audit_has "$MARK" completionCheck "" notDone && audit_has "$MARK" toolResult ui_click ok && ! audit_has "$MARK" confirmation && reply_has "Playing" && echo 0 || echo 1)"

ask "move report"
check "moving a file runs without asking" \
    "$(audit_has "$MARK" policyDecision file_move auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult file_move ok && reply_has "Moved" && echo 0 || echo 1)"

ask "trash screenshots"
check "trashing files runs without asking, after the search that found them" \
    "$(audit_has "$MARK" policyDecision file_trash auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult file_trash ok && echo 0 || echo 1)"

ask "trash ssh"
check "a file in a hidden folder is still refused outright" \
    "$(audit_has "$MARK" policyDecision file_trash deny && ! audit_has "$MARK" toolResult file_trash ok && reply_has "can't touch" && echo 0 || echo 1)"

ask "ui password"
check "typing into a password field is still refused outright" \
    "$(audit_has "$MARK" policyDecision ui_type deny && ! audit_has "$MARK" toolResult ui_type ok && reply_has "password field" && echo 0 || echo 1)"

ask "shell"
check "a script that runs a shell command is still refused, and nobody is asked" \
    "$(audit_has "$MARK" policyDecision run_applescript deny && ! audit_has "$MARK" confirmation && reply_has "can't run shell" && echo 0 || echo 1)"

ask "add numbers"
check "a script runs without asking, and the trail says it ran on the user's say-so" \
    "$(audit_has "$MARK" policyDecision run_applescript auto && ! audit_has "$MARK" confirmation && audit_has "$MARK" toolResult run_applescript ok && reply_has "42" && echo 0 || echo 1)"

check "the status report says nothing is left waiting" "$(! report_has "awaiting=true" && echo 0 || echo 1)"
check "every request the app made was a valid one" "$(requests_valid anthropic && echo 0 || echo 1)"

# The sections after this one are about how Voxa behaves out of the box, so put the setting back before the next launch reads it.
settings ""

# ---------------------------------------------------------------------------------------------------------------------------
log "The completion check can be turned off"
settings ',"verifyCompletion":false'
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$ALL"

ask "ui lazy"
check "with the check off, the model's early reply stands and nothing is checked" \
    "$(! audit_has "$MARK" completionCheck && reply_has "Pressed" && echo 0 || echo 1)"
settings ""

# ---------------------------------------------------------------------------------------------------------------------------
log "A web page and a file name with instructions hidden in them"
launch --env VOXA_DEBUG_SAMPLE_DATA=hostile --env "VOXA_DEBUG_TOOL_PERMISSIONS=$ALL"
ask "ui inject"
check "the fooled model's request to open a link is stopped and put to the user" "$(audit_has "$MARK" policyDecision open_url confirm && echo 0 || echo 1)"
answer deny
check "declined, the link is never opened" "$(! audit_has "$MARK" toolResult open_url ok && reply_has "didn't open" && echo 0 || echo 1)"
ask "file inject"
check "so is one prompted by a file name" "$(audit_has "$MARK" policyDecision open_url confirm && echo 0 || echo 1)"
answer deny
check "and declined the same way" "$(! audit_has "$MARK" toolResult open_url ok && reply_has "didn't open" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "The permission gate for windows and the screen"
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED,accessibility=denied,screenRecording=denied"
ask "ui inspect"
check "without Accessibility the command ends with an error, and nothing is read" \
    "$(audit_has "$MARK" permission ui_inspect denied && audit_has "$MARK" failure && ! audit_has "$MARK" toolResult ui_inspect && echo 0 || echo 1)"
ask "shot window"
check "without Screen Recording no picture is taken" \
    "$(audit_has "$MARK" permission screenshot denied && audit_has "$MARK" failure && ! audit_has "$MARK" toolResult screenshot && echo 0 || echo 1)"
ask "find invoices"
check "the file tools need no permission of their own" "$(audit_has "$MARK" toolResult file_search ok && echo 0 || echo 1)"

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
hook say
check "the voice starts speaking" "$(wait_for 5 report_has "speaking=true" && echo 0 || echo 1)"
check "and finishes on its own" "$(wait_for 15 report_has "speaking=false" && echo 0 || echo 1)"

# A whole command whose reply is spoken, cut off by Esc while the reply is up. (The shortcut itself is not pressed here: with
# the microphone not yet allowed to this build, that would bring up the system's permission prompt.)
launch --env VOXA_DEBUG_SAMPLE_DATA=1 --env "VOXA_DEBUG_TOOL_PERMISSIONS=$GRANTED"
ask "add lunch"
check "the reply is spoken as well as shown" "$(wait_for 5 report_has "speaking=true" && echo 0 || echo 1)"
hook key.escape
check "Esc cuts the speech off at once" "$(wait_for 3 report_has "speaking=false" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------------------------------------------------------
log "The first-run walkthrough"
write_settings '{"localeIdentifier":"en_US","onboardingCompleted":false,"speakReplies":false}'
launch
check "a first run opens the walkthrough by itself" "$(report_has "welcome=true" && echo 0 || echo 1)"
hook onboarding.close
check "and it can be closed" "$(wait_for 3 report_has "welcome=false" && echo 0 || echo 1)"

write_settings '{"localeIdentifier":"en_US","onboardingCompleted":true,"speakReplies":false}'
launch
check "once finished, the walkthrough does not open by itself again" "$(report_has "welcome=false" && echo 0 || echo 1)"
hook onboarding
check "but it can be opened again on request" "$(wait_for 3 report_has "welcome=true" && echo 0 || echo 1)"
hook onboarding.close
wait_for 3 report_has "welcome=false" || true
hook button.welcomeGuide
check "and so can it from the button in Settings" "$(wait_for 3 report_has "welcome=true" && echo 0 || echo 1)"

log "The Settings tabs"
for tab in general model tools permissions safety history; do
    hook "settings.tab.$tab"
    check "Settings opens on the $tab tab" "$(wait_for 3 report_has "settingsTab=$tab" && echo 0 || echo 1)"
done

e2e_finish
