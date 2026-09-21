!/bin/bash

# ==============================================================================
# Freightseeker - Kvitton IMAP Cleanup
# ==============================================================================
#
# PURPOSE
# -------
# Cleans old emails from the "Kvitton" IMAP folder on Freightseeker/GleSYS
# email accounts.
#
# The script:
#   1. Asks for your email address.
#   2. Asks how many old emails you want to process.
#   3. Asks for your email password (input is hidden).
#   4. Finds emails older than one year in INBOX.Kvitton.
#   5. Validates that the selected emails are actually older than one year.
#   6. Shows a summary and asks for confirmation.
#   7. Validates the emails AGAIN immediately before moving them.
#   8. Moves them to INBOX.Trash.
#
# IMPORTANT
# ---------
# Emails are moved to Trash. They are NOT permanently deleted by this script.
#
# The script will abort if its safety validation finds a selected email that
# is not older than the cutoff date.
#
#
# REQUIREMENTS
# ------------
#   - macOS
#   - Terminal
#   - curl (included with macOS)
#   - Access to the Freightseeker/GleSYS IMAP account
#
#
# RUN DIRECTLY FROM GITHUB
# ------------------------
# Open Terminal on your Mac and run:
#
#   bash <(curl -fsSL "https://raw.githubusercontent.com/freightseeker/Scripts/master/cleanup-kvitton-imap-inbox.sh")
#
#
# RUN A LOCAL COPY
# ----------------
# If you have downloaded the script:
#
#   chmod +x cleanup-kvitton-imap-inbox.sh
#   ./cleanup-kvitton-imap-inbox.sh
#
#
# EXAMPLE
# -------
#   $ bash <(curl -fsSL "https://raw.githubusercontent.com/freightseeker/Scripts/master/cleanup-kvitton-imap-inbox.sh")
#
#   ============================================================
#   KVITTON CLEANUP
#   ============================================================
#
#   Email address: user@freightseeker.com
#   How many old emails do you want to move to Trash? 1000
#   Password for user@freightseeker.com:
#
#   ...
#
#   VALIDATION PASSED
#
#   Emails selected:   1000
#   Emails validated:  1000
#   Cutoff:             before 21-Sep-2025
#   From:               INBOX.Kvitton
#   To:                 INBOX.Trash
#
#   Move these 1000 emails to Trash? (yes/no): yes
#
#   Moving emails...
#
#   Moved 500 / 1000
#   Moved 1000 / 1000
#
#   DONE
#
#
# SECURITY
# --------
# Never put your email password in this file.
#
# The password is requested interactively and is not displayed while typing.
# The script does not save the password to disk.
#
#
# NOTES
# -----
# - Only emails older than one year are selected.
# - The cutoff is based on the IMAP server's INTERNALDATE.
# - Emails on the cutoff date itself are NOT selected.
# - Messages are processed in batches to support very large mailboxes.
# - Every batch is validated again immediately before it is moved.
# - Enter anything other than exactly "yes" at the confirmation prompt to
#   cancel the operation.
#
# ==============================================================================

IMAP_SERVER="mail.glesys.se"
IMAP_PORT="993"
EMAIL="mattias@freightseeker.com"

MAILBOX="INBOX.Kvitton"
TRASH="INBOX.Trash"

SEARCH_CHUNK=5000
MOVE_BATCH_SIZE=500

echo
echo "============================================================"
echo "KVITTON CLEANUP"
echo "============================================================"
echo

read -p "How many old emails do you want to move to Trash? " LIMIT

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Enter a positive whole number."
    exit 1
fi

echo -n "IMAP password: "
read -s PASSWORD
echo
echo

# macOS: one year ago
BEFORE=$(date -v-1y +"%d-%b-%Y")

echo "Mailbox:     $MAILBOX"
echo "Destination: $TRASH"
echo "Cutoff:      before $BEFORE"
echo "Requested:   $LIMIT"
echo
echo "Searching for old emails..."

# ============================================================
# Temporary files
# ============================================================

TMP_UIDS=$(mktemp)
BATCH_FILE=$(mktemp)

cleanup()
{
    rm -f "$TMP_UIDS" "$BATCH_FILE"
}

trap cleanup EXIT

# ============================================================
# Search in chunks
# ============================================================

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

    # Safety against accidental endless scanning
    if [ "$START" -gt 1000000 ]; then
        echo
        echo "Safety stop after 1,000,000 mailbox positions."
        break
    fi

done

# Keep only requested number
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

# ============================================================
# Function:
# Verify NONE of these UIDs are SINCE cutoff
# ============================================================

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

# ============================================================
# Validate ALL selected messages before asking user
# ============================================================

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

# Remaining messages
BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

if [ "$BATCH_COUNT" -gt 0 ]; then

    UID_SET=$(paste -sd, "$BATCH_FILE")

    check_batch_is_old "$UID_SET"

    VALIDATED=$((VALIDATED + BATCH_COUNT))
fi

# ============================================================
# Confirmation
# ============================================================

echo
echo "============================================================"
echo "VALIDATION PASSED"
echo "============================================================"
echo
echo "Emails selected:  $COUNT"
echo "Emails validated: $VALIDATED"
echo "Cutoff:            before $BEFORE"
echo "From:              $MAILBOX"
echo "To:                $TRASH"
echo
echo "No individual emails are displayed."
echo "Messages will be MOVED to Trash, not permanently deleted."
echo

read -p "Move these $COUNT emails to Trash? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo
    echo "Cancelled. Nothing has been moved."
    exit 0
fi

# ============================================================
# Move in batches
# ============================================================

echo
echo "Moving emails..."

MOVED=0
> "$BATCH_FILE"

move_batch()
{
    UID_SET=$(paste -sd, "$BATCH_FILE")

    [ -z "$UID_SET" ] && return

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

    # --------------------------------------------------------
    # FINAL safety check immediately before MOVE
    # --------------------------------------------------------

    check_batch_is_old "$UID_SET"

    # --------------------------------------------------------
    # Move to Trash
    # --------------------------------------------------------

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
        echo "$MOVED emails were moved before the failure."
        exit 1
    fi

    MOVED=$((MOVED + BATCH_COUNT))

    echo "Moved $MOVED / $COUNT"

    > "$BATCH_FILE"
}

while IFS= read -r MSG_UID; do

    echo "$MSG_UID" >> "$BATCH_FILE"

    BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

    if [ "$BATCH_COUNT" -ge "$MOVE_BATCH_SIZE" ]; then
        move_batch
    fi

done < "$TMP_UIDS"

# Move final partial batch
BATCH_COUNT=$(wc -l < "$BATCH_FILE" | tr -d ' ')

if [ "$BATCH_COUNT" -gt 0 ]; then
    move_batch
fi

echo
echo "============================================================"
echo "DONE"
echo "============================================================"
echo
echo "Moved:  $MOVED emails"
echo "Cutoff: before $BEFORE"
echo
echo "$MAILBOX"
echo "    -> $TRASH"
echo
echo "No emails were permanently deleted."
echo "============================================================"
