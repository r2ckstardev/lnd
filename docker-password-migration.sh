#!/bin/bash

# BTCPay's startup coordination only. LND and its databases are unchanged.
prepare_password_migration() {
    local data="$1" wallet_dir="$2" unlock old pending backup file relative
    unlock="$wallet_dir/walletunlock.json"
    export LND_DEFER_MACAROON_ROTATION=0
    [[ -f "$wallet_dir/wallet.db" && -f "$unlock" ]] || return 0

    old=$(jq -r '.wallet_password // ""' "$unlock") || return 1
    pending=$(jq -r 'has("wallet_password_pending")' "$unlock") || return 1
    if [[ "$pending" == "true" ]]; then
        jq -e '.wallet_password_pending | type == "string" and length >= 8' \
            "$unlock" >/dev/null || return 1

        # An interrupted ChangePassword may have committed wallet.db but not
        # macaroons.db. Preserve the latter and its tokens before LND opens
        # them, so a normal unlock can create a consistent store. These are
        # authentication files only: never move wallet.db or channel.db.
        # Old credentials are invalidated; clients need pairing again.
        (
            umask 077
            backup=""
            while IFS= read -r -d '' file; do
                if [[ -z "$backup" ]]; then
                    mkdir -p "$data/.password-migration-backups" || exit 1
                    backup=$(mktemp -d "$data/.password-migration-backups/attempt.XXXXXX") || exit 1
                fi
                relative=${file#"$data/"}
                mkdir -p "$backup/$(dirname "$relative")" || exit 1
                mv "$file" "$backup/$relative" || exit 1
            done < <(find "$data" -path "$data/.password-migration-backups" -prune -o \
                -type f \( -name '*.macaroon' -o -name 'macaroons.db' \) -print0)
            sync || exit 1
        ) || return 1
        echo "[lnd_unlock_entrypoint] Resuming a pending password change; previous macaroon files are preserved in $data/.password-migration-backups"
    fi

    # First change the password against the existing root key. After a
    # successful migration the helper asks this container to restart, and
    # the regular one-time rotation runs before the next normal unlock.
    if [[ "$old" == "hellorockstar" || -z "$old" || "$pending" == "true" ]]; then
        export LND_DEFER_MACAROON_ROTATION=1
    fi
}

restart_after_password_migration() {
    # Set only by our entrypoint, immediately before it execs LND. Never find
    # or signal a process by name, and never signal an arbitrary parent.
    if [[ "${LND_DAEMON_PID:-}" =~ ^[0-9]+$ && "$LND_DAEMON_PID" == "$PPID" ]]; then
        echo "[initunlocklnd] Restarting lnd to finish password and macaroon initialization"
        kill -TERM "$LND_DAEMON_PID"
    else
        echo "[initunlocklnd] Restart the LND container to finish password and macaroon initialization"
    fi
    exit 1
}
