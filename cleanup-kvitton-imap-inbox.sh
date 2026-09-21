#!/bin/bash

# ==============================================================================
# Freightseeker - Kvitton IMAP Cleanup
# ==============================================================================
# PURPOSE
# -------
# Moves old emails from INBOX.Kvitton to INBOX.Trash on the GleSYS
# IMAP server.
#
# The script:
#   1. Asks for the email address.
#   2. Asks how many old emails to process.
#   3. Asks for the email password (input is hidden).
#   4. Searches INBOX.Kvitton for emails with an IMAP internal date
#      older than one year.
#   5. Selects up to the requested number of old emails.
#   6. Validates that none of the selected messages have an IMAP
#      internal date on or after the cutoff date.
#   7. Shows a summary and asks for explicit confirmation.
#   8. Revalidates every batch immediately before moving it.
#   9. Moves the validated messages to INBOX.Trash.
#
# IMPORTANT
# ---------
# This script does NOT permanently delete messages.
#
# Messages are moved:
#
#   INBOX.Kvitton -> INBOX.Trash
#
# The Trash folder may be emptied later by the mail server, mail client,
# retention policy, or manually by the user. This script does not control
# what happens to messages after they have been moved to Trash.
#
# DATE SAFETY
# -----------
# The script uses the IMAP search criteria BEFORE and SINCE.
#
# These criteria use the message's IMAP internal date, not the Date:
# header supplied by the sender.
#
# For example:
#
#   BEFORE 21-Sep-2025
#
# selects messages whose internal date is strictly before 21-Sep-2025.
#
# Messages dated 21-Sep-2025 itself are NOT selected.
#
# Before anything is moved, the script also checks the selected UIDs using:
#
#   UID SEARCH UID <selected UIDs> SINCE <cutoff>
#
# If the server returns ANY selected UID, the safety check fails and the
# operation is aborted.
#
# The same validation is performed again immediately before each MOVE.
#
# LARGE MAILBOXES
# ---------------
# The mailbox may contain hundreds of thousands of messages.
#
# To avoid excessively large IMAP responses:
#
#   - The mailbox is searched in chunks.
#   - Messages are moved in batches of 500.
#   - Individual messages are not printed to the terminal.
#
# REQUIREMENTS
# ------------
#   - macOS
#   - Terminal
#   - curl (included with macOS)
#   - A valid GleSYS email account with access to INBOX.Kvitton
#
# RUN DIRECTLY FROM GITHUB
# ------------------------
# Open Terminal and run:
#
#   bash <(curl -fsSL "https://raw.githubusercontent.com/freightseeker/Scripts/master/cleanup-kvitton-imap-inbox.sh")
#
# RUN A LOCAL COPY
# ----------------
# Download the script and run:
#
#   chmod +x cleanup-kvitton-imap-inbox.sh
#   ./cleanup-kvitton-imap-inbox.sh
#
# EXAMPLE
# -------
#   ============================================================
#   KVITTON CLEANUP
#   ============================================================
#
#   Email address: user@freightseeker.com
#   How many old emails do you want to move to Trash? 1000
#   Password for user@freightseeker.com:
#
#   ============================================================
#   SETTINGS
#   ============================================================
#   Account:     user@freightseeker.com
#   Mailbox:     INBOX.Kvitton
#   Destination: INBOX.Trash
#   Cutoff:      before 21-Sep-2025
#   Requested:   1000
#   ============================================================
#
#   Searching for old emails...
#
#   Found 1000 old emails.
#   Validating selection...
#
#   ============================================================
#   VALIDATION PASSED
#   ============================================================
#
#   Emails selected:  1000
#   Emails validated: 1000
#   Cutoff:            before 21-Sep-2025
#   From:              INBOX.Kvitton
#   To:                INBOX.Trash
#
#   Move these 1000 emails to Trash? (yes/no): yes
#
#   Moving emails...
#
#   Moved 500 / 1000
#   Moved 1000 / 1000
#
#   ============================================================
#   DONE
#   ============================================================
#
# SECURITY
# --------
# Do not store email passwords in this script or in GitHub.
#
# The password is requested interactively using "read -s", so it is not
# displayed while being entered.
#
# The script keeps the password in memory only for the duration of the
# process and does not intentionally write it to disk.
#
# CANCELLATION
# ------------
# The script asks:
#
#   Move these N emails to Trash? (yes/no):
#
# Only exactly:
#
#   yes
#
# continues with the MOVE operation.
#
# Any other response cancels the operation before messages are moved.
# ==============================================================================


# ==============================================================================
# Configuration
# ==============================================================================

IMAP_SERVER="mail.glesys.se"
IMAP_PORT="993"

MAILBOX="INBOX.Kvitton"
TRASH="INBOX.Trash"

# Search mailbox in chunks to prevent huge IMAP SEARCH responses.
SEARCH_CHUNK=5000

# Move messages in smaller batches.
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
# ==============================================================================

read -p "Email address: " EMAIL

if [ -z "$EMAIL" ]; then
    echo
    echo "ERROR: Email address cannot be empty."
    exit 1
fi


# ==============================================================================
# Number of emails
# ==============================================================================

read -p "How many old emails do you want to move to Trash? " LIMIT

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo
    echo "ERROR: Enter a positive whole number."
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
# Calculate cutoff
#
# macOS date syntax.
#
# IMAP BEFORE works with calendar dates.
#
# Example:
#
#   BEFORE 21-Sep-2025
#
# means strictly before 21-Sep-2025.
#
# Emails dated 21-Sep-2025 are therefore NOT selected.
# ==============================================================================

BEFORE=$(date -v-1y +"%d-%b-%Y")


# ==============================================================================
# Show settings
# ==============================================================================

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
#
# We intentionally do NOT perform one huge:
#
#   UID SEARCH BEFORE ...
#
# because mailboxes containing hundreds of thousands of emails can generate
# an IMAP response too large for curl.
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
        echo
        echo "Check:"
        echo "  - Email address"
        echo "  - Password"
        echo "  - IMAP connection"
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

    # Prevent an accidental endless scan.
    if [ "$START" -gt 1000000 ]; then
        echo
        echo "Safety stop after searching 1,000,000 mailbox positions."
        break
    fi

done


# ==============================================================================
# Keep exactly the requested number
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
#
# For the supplied UIDs, ask the IMAP server if ANY message has an
# INTERNALDATE on or after the cutoff.
#
# Example:
#
#   UID SEARCH UID 9190,9191,9192 SINCE 21-Sep-2025
#
# A safe response contains no UIDs:
#
#   * SEARCH
#
# If ANY UID is returned, the entire operation is aborted.
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
# Validate ALL selected emails before asking for confirmation
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


# ==============================================================================
# Validate remaining messages
# ==============================================================================

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
#
# IMPORTANT:
#
# Every batch is validated AGAIN immediately before the UID MOVE command.
#
# This means the safety validation happens:
#
#   1. Before asking the user for confirmation.
#   2. Immediately before each MOVE.
# ==============================================================================

move_batch()
{
    UID_SET=$(paste -sd, "$BATCH_FILE")

    [ -z "$UID_SET" ] && return

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')


    # --------------------------------------------------------------------------
    # Final safety check
    # --------------------------------------------------------------------------

    check_batch_is_old "$UID_SET"


    # --------------------------------------------------------------------------
    # Move validated emails to Trash
    # --------------------------------------------------------------------------

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


# ==============================================================================
# Move final partial batch
# ==============================================================================

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
