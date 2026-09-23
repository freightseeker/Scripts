#!/bin/bash

# ==============================================================================
# Freightseeker - Kvitton IMAP Cleanup
# ==============================================================================
# PURPOSE
# -------
# Moves old emails from a selected Kvitton folder to the account's Trash folder
# on the GleSYS IMAP server.
#
# The script:
#   1. Gets the email address from the command line or asks for it.
#   2. Asks for the email password (input is hidden).
#   3. Retrieves the account's IMAP folders.
#   4. Automatically finds a folder named "Kvitton" (case-insensitive).
#   5. Lets the user select a folder if Kvitton cannot be uniquely identified.
#   6. Automatically finds the Trash folder.
#   7. Asks how many old emails to process.
#   8. Finds emails older than one year.
#   9. Validates all selected messages before confirmation.
#  10. Asks for explicit confirmation.
#  11. Revalidates every batch immediately before moving it.
#  12. Moves the validated messages to Trash.
#
# IMPORTANT
# ---------
# This script does NOT permanently delete messages.
#
# Messages are moved from the selected source folder to Trash.
#
# The Trash folder may be emptied later by the mail server, mail client,
# retention policy, or manually by the user.
#
# DATE SAFETY
# -----------
# IMAP BEFORE and SINCE use the message's IMAP internal date, not the Date:
# header supplied by the sender.
#
# Example:
#
#   BEFORE 23-Sep-2025
#
# means strictly before 23-Sep-2025.
#
# Messages dated 23-Sep-2025 itself are NOT selected.
#
# Before anything is moved, selected UIDs are checked using:
#
#   UID SEARCH UID <selected UIDs> SINCE <cutoff>
#
# If ANY selected UID is returned, the operation is aborted.
#
# Every batch is validated again immediately before MOVE.
#
# REQUIREMENTS
# ------------
#   - macOS
#   - Terminal
#   - curl (included with macOS)
#   - Access to the GleSYS IMAP account
#
# RUN DIRECTLY FROM GITHUB
# ------------------------
# Recommended:
#
#   bash <(curl -fsSL "https://raw.githubusercontent.com/freightseeker/Scripts/master/cleanup-kvitton-imap-inbox.sh") user@freightseeker.com
#
# You can also omit the email address:
#
#   bash <(curl -fsSL "https://raw.githubusercontent.com/freightseeker/Scripts/master/cleanup-kvitton-imap-inbox.sh")
#
# The script will then ask for it.
#
# SECURITY
# --------
# Do NOT put the email password in this file, GitHub, or the command line.
#
# The password is requested interactively using "read -s", so it is not
# displayed while being entered.
# ==============================================================================


# ==============================================================================
# Configuration
# ==============================================================================

IMAP_SERVER="mail.glesys.se"
IMAP_PORT="993"

SEARCH_CHUNK=5000
MOVE_BATCH_SIZE=500


# ==============================================================================
# Start
# ==============================================================================

echo
echo "============================================================"
echo "KVITTON CLEANUP"
echo "============================================================"
echo


# ==============================================================================
# Email address
#
# First command-line argument can contain the email address.
#
# Example:
#
#   ./cleanup-kvitton-imap-inbox.sh user@freightseeker.com
# ==============================================================================

EMAIL="$1"

if [ -z "$EMAIL" ]; then
    read -p "Email address: " EMAIL
fi

if [ -z "$EMAIL" ]; then
    echo
    echo "ERROR: Email address cannot be empty."
    exit 1
fi


# ==============================================================================
# Password
# ==============================================================================

echo -n "Password for $EMAIL: "
read -s PASSWORD
echo
echo


# ==============================================================================
# Retrieve IMAP folders
# ==============================================================================

echo "Connecting to IMAP server..."
echo

LIST_RESULT=$(curl \
    --silent \
    --show-error \
    --fail \
    --url "imaps://${IMAP_SERVER}:${IMAP_PORT}/" \
    --user "${EMAIL}:${PASSWORD}" \
    --request 'LIST "" "*"')

if [ $? -ne 0 ]; then
    echo
    echo "ERROR: Could not connect to IMAP server."
    echo
    echo "Check:"
    echo "  - Email address"
    echo "  - Password"
    echo "  - Internet connection"
    exit 1
fi


# ==============================================================================
# Extract mailbox names from LIST response
#
# Handles normal Dovecot responses such as:
#
#   * LIST (\HasNoChildren) "." INBOX.Kvitton
#   * LIST (\HasNoChildren) "." "INBOX.kvitton"
#
# The folder names are stored exactly as returned by the server.
# ==============================================================================

FOLDERS=$(echo "$LIST_RESULT" \
    | sed -E 's/.*"[^"]*" ("([^"]+)"|([^ ]+))\r?$/\2\3/' \
    | grep -v '^\* LIST ' \
    | sed '/^[[:space:]]*$/d')

if [ -z "$FOLDERS" ]; then
    echo
    echo "ERROR: Could not read the IMAP folder list."
    exit 1
fi


# ==============================================================================
# Find Kvitton folder
#
# Match case-insensitively.
#
# Examples:
#
#   Kvitton
#   kvitton
#   INBOX.Kvitton
#   INBOX.kvitton
#
# Only the final folder component must equal "kvitton".
# ==============================================================================

KVITTON_MATCHES=$(echo "$FOLDERS" \
    | awk 'BEGIN { IGNORECASE=1 }
           {
               n=split($0,a,".")
               if (tolower(a[n]) == "kvitton")
                   print $0
           }')

KVITTON_COUNT=$(echo "$KVITTON_MATCHES" \
    | sed '/^[[:space:]]*$/d' \
    | wc -l \
    | tr -d ' ')


# ==============================================================================
# Select source folder
# ==============================================================================

if [ "$KVITTON_COUNT" -eq 1 ]; then

    MAILBOX="$KVITTON_MATCHES"

    echo "Kvitton folder found:"
    echo
    echo "  $MAILBOX"
    echo

    read -p "Use this folder? (yes/no): " USE_KVITTON

    if [ "$USE_KVITTON" != "yes" ]; then
        MAILBOX=""
    fi

else
    MAILBOX=""
fi


# ==============================================================================
# Manual folder selection
# ==============================================================================

if [ -z "$MAILBOX" ]; then

    echo
    echo "Available IMAP folders:"
    echo

    i=1

    while IFS= read -r FOLDER; do
        printf "  %3d) %s\n" "$i" "$FOLDER"
        i=$((i + 1))
    done <<< "$FOLDERS"

    echo

    FOLDER_COUNT=$((i - 1))

    read -p "Select source folder [1-$FOLDER_COUNT]: " FOLDER_NUMBER

    if ! [[ "$FOLDER_NUMBER" =~ ^[0-9]+$ ]] \
        || [ "$FOLDER_NUMBER" -lt 1 ] \
        || [ "$FOLDER_NUMBER" -gt "$FOLDER_COUNT" ]; then

        echo
        echo "ERROR: Invalid folder selection."
        exit 1
    fi

    MAILBOX=$(echo "$FOLDERS" | sed -n "${FOLDER_NUMBER}p")
fi


# ==============================================================================
# Find Trash folder
#
# First try the IMAP SPECIAL-USE flag \Trash.
#
# If unavailable, look for common Trash folder names.
# ==============================================================================

TRASH=$(echo "$LIST_RESULT" \
    | awk '
        BEGIN { IGNORECASE=1 }
        /\\Trash/ {
            line=$0
            sub(/\r$/, "", line)

            if (match(line, /"[^"]+"$/)) {
                value=substr(line, RSTART+1, RLENGTH-2)
                print value
                exit
            }

            n=split(line,a," ")
            print a[n]
            exit
        }
    ')

if [ -z "$TRASH" ]; then

    TRASH=$(echo "$FOLDERS" \
        | awk '
            {
                n=split($0,a,".")
                last=tolower(a[n])

                if (last == "trash" || last == "deleted messages") {
                    print $0
                    exit
                }
            }
        ')
fi

if [ -z "$TRASH" ]; then
    echo
    echo "ERROR: Could not automatically identify the Trash folder."
    echo
    echo "Nothing has been moved."
    exit 1
fi


# ==============================================================================
# Prevent source = destination
# ==============================================================================

if [ "$MAILBOX" = "$TRASH" ]; then
    echo
    echo "ERROR: The selected source folder is the Trash folder."
    exit 1
fi


# ==============================================================================
# Number of emails
# ==============================================================================

echo
read -p "How many old emails do you want to move to Trash? " LIMIT

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo
    echo "ERROR: Enter a positive whole number."
    exit 1
fi


# ==============================================================================
# Calculate cutoff
# ==============================================================================

BEFORE=$(date -v-1y +"%d-%b-%Y")


# ==============================================================================
# Show settings
# ==============================================================================

echo
echo "============================================================"
echo "SETTINGS"
echo "============================================================"
echo "Account:     $EMAIL"
echo "Mailbox:     $MAILBOX"
echo "Destination: $TRASH"
echo "Cutoff:      before $BEFORE"
echo "Requested:   $LIMIT"
echo "============================================================"
echo

echo "Searching for old emails..."


# ==============================================================================
# Temporary files
# ==============================================================================

TMP_UIDS=$(mktemp)
BATCH_FILE=$(mktemp)

cleanup()
{
    rm -f "$TMP_UIDS" "$BATCH_FILE"
}

trap cleanup EXIT


# ==============================================================================
# Search mailbox in chunks
# ==============================================================================

START=1

while true; do

    CURRENT_COUNT=$(wc -l < "$TMP_UIDS" | tr -d ' ')

    if [ "$CURRENT_COUNT" -ge "$LIMIT" ]; then
        break
    fi

    END=$((START + SEARCH_CHUNK - 1))

    RESULT=$(curl \
        --silent \
        --show-error \
        --fail \
        --url "imaps://${IMAP_SERVER}:${IMAP_PORT}/${MAILBOX}" \
        --user "${EMAIL}:${PASSWORD}" \
        --request "UID SEARCH ${START}:${END} BEFORE ${BEFORE}")

    if [ $? -ne 0 ]; then
        echo
        echo "ERROR: IMAP search failed."
        exit 1
    fi

    FOUND=$(echo "$RESULT" \
        | sed -n 's/^\* SEARCH //p' \
        | tr ' ' '\n' \
        | grep -E '^[0-9]+$')

    if [ -n "$FOUND" ]; then
        echo "$FOUND" >> "$TMP_UIDS"
    fi

    START=$((END + 1))

    if [ "$START" -gt 1000000 ]; then
        echo
        echo "Safety stop after searching 1,000,000 mailbox positions."
        break
    fi

done


# ==============================================================================
# Keep requested number
# ==============================================================================

head -n "$LIMIT" "$TMP_UIDS" > "${TMP_UIDS}.limited"
mv "${TMP_UIDS}.limited" "$TMP_UIDS"

COUNT=$(wc -l < "$TMP_UIDS" | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    echo
    echo "No emails older than $BEFORE found."
    exit 0
fi

echo
echo "Found $COUNT old emails."
echo "Validating selection..."


# ==============================================================================
# Safety validation
# ==============================================================================

check_batch_is_old()
{
    UID_SET="$1"

    RESULT=$(curl \
        --silent \
        --show-error \
        --fail \
        --url "imaps://${IMAP_SERVER}:${IMAP_PORT}/${MAILBOX}" \
        --user "${EMAIL}:${PASSWORD}" \
        --request "UID SEARCH UID ${UID_SET} SINCE ${BEFORE}")

    if [ $? -ne 0 ]; then
        echo
        echo "ERROR: IMAP safety validation failed."
        exit 1
    fi

    NEWER_UIDS=$(echo "$RESULT" \
        | sed -n 's/^\* SEARCH //p' \
        | tr ' ' '\n' \
        | grep -E '^[0-9]+$')

    if [ -n "$NEWER_UIDS" ]; then

        echo
        echo "============================================================"
        echo "SAFETY CHECK FAILED"
        echo "============================================================"
        echo
        echo "At least one selected email has an INTERNALDATE"
        echo "on or after:"
        echo
        echo "  $BEFORE"
        echo
        echo "Nothing from this batch has been moved."
        echo

        exit 1
    fi
}


# ==============================================================================
# Validate all selected messages
# ==============================================================================

VALIDATED=0

> "$BATCH_FILE"

while IFS= read -r MSG_UID; do

    echo "$MSG_UID" >> "$BATCH_FILE"

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

    if [ "$BATCH_COUNT" -ge "$MOVE_BATCH_SIZE" ]; then

        UID_SET=$(paste -sd, "$BATCH_FILE")

        check_batch_is_old "$UID_SET"

        VALIDATED=$((VALIDATED + BATCH_COUNT))

        > "$BATCH_FILE"
    fi

done < "$TMP_UIDS"

BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

if [ "$BATCH_COUNT" -gt 0 ]; then

    UID_SET=$(paste -sd, "$BATCH_FILE")

    check_batch_is_old "$UID_SET"

    VALIDATED=$((VALIDATED + BATCH_COUNT))
fi


# ==============================================================================
# User confirmation
# ==============================================================================

echo
echo "============================================================"
echo "VALIDATION PASSED"
echo "============================================================"
echo
echo "Account:          $EMAIL"
echo "Emails selected:  $COUNT"
echo "Emails validated: $VALIDATED"
echo "Cutoff:            before $BEFORE"
echo "From:              $MAILBOX"
echo "To:                $TRASH"
echo
echo "No individual emails are displayed."
echo
echo "IMPORTANT:"
echo "The messages will be MOVED to Trash."
echo "They will NOT be permanently deleted by this script."
echo
echo "============================================================"
echo

read -p "Move these $COUNT emails to Trash? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo
    echo "Cancelled."
    echo "Nothing has been moved."
    exit 0
fi


# ==============================================================================
# Move messages
# ==============================================================================

echo
echo "Moving emails..."
echo

MOVED=0

> "$BATCH_FILE"


# ==============================================================================
# Move one batch
# ==============================================================================

move_batch()
{
    UID_SET=$(paste -sd, "$BATCH_FILE")

    [ -z "$UID_SET" ] && return

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

    # Final safety validation immediately before MOVE.
    check_batch_is_old "$UID_SET"

    curl \
        --silent \
        --show-error \
        --fail \
        --url "imaps://${IMAP_SERVER}:${IMAP_PORT}/${MAILBOX}" \
        --user "${EMAIL}:${PASSWORD}" \
        --request "UID MOVE ${UID_SET} ${TRASH}" \
        > /dev/null

    if [ $? -ne 0 ]; then
        echo
        echo "ERROR: IMAP MOVE failed."
        echo
        echo "$MOVED emails were successfully moved before the failure."
        exit 1
    fi

    MOVED=$((MOVED + BATCH_COUNT))

    echo "Moved $MOVED / $COUNT"

    > "$BATCH_FILE"
}


# ==============================================================================
# Process selected messages
# ==============================================================================

while IFS= read -r MSG_UID; do

    echo "$MSG_UID" >> "$BATCH_FILE"

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

    if [ "$BATCH_COUNT" -ge "$MOVE_BATCH_SIZE" ]; then
        move_batch
    fi

done < "$TMP_UIDS"

BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

if [ "$BATCH_COUNT" -gt 0 ]; then
    move_batch
fi


# ==============================================================================
# Done
# ==============================================================================

echo
echo "============================================================"
echo "DONE"
echo "============================================================"
echo
echo "Account: $EMAIL"
echo "Moved:   $MOVED emails"
echo "Cutoff:  before $BEFORE"
echo
echo "$MAILBOX"
echo "    -> $TRASH"
echo
echo "No emails were permanently deleted."
echo "============================================================"
echo
