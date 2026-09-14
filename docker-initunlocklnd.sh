#!/bin/bash
set -e
umask 077
. "$(dirname "$0")/docker-password-migration.sh"

# Keep the previous password and a pending replacement in the same durable
# document. ChangePassword can commit wallet.db and still return an error.
# Never send a replacement to LND until it can be recovered from this file.
save_unlock_file() {
    local temporary
    temporary=$(mktemp "$LNDUNLOCK_FILE.tmp.XXXXXX") || return 1
    if ! jq -c "$@" "$LNDUNLOCK_FILE" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod 600 "$temporary" || return 1
    sync || return 1
    mv -f "$temporary" "$LNDUNLOCK_FILE" || return 1
    sync || return 1
}

wallet_request() {
    local endpoint="$1" payload="$2"
    # A transport failure is an uncertain outcome, not proof of rollback.
    curl -s --connect-timeout 10 --max-time 120 --cacert "$CA_CERT" \
        -X POST -H "$MACAROON_HEADER" -d "$payload" \
        "$LND_REST_LISTEN_HOST/v1/$endpoint"
}

request_succeeded() {
    jq -e 'type == "object" and (length == 0 or
        (has("admin_macaroon") and (.admin_macaroon | type == "string")))' \
        >/dev/null 2>&1 <<< "$1"
}

wrong_wallet_password() {
    # Only this pre-mutation wallet-open error justifies trying the legacy
    # newline variant. Preserve all other errors instead of hiding them.
    jq -e '.message == "invalid passphrase for master public key"' \
        >/dev/null 2>&1 <<< "$1"
}

finish_password_migration() {
    save_unlock_file '.wallet_password = .wallet_password_pending |
        del(.wallet_password_pending)' || return 1
    echo "[initunlocklnd] Migrated wallet off the default password; the new random password is in $LNDUNLOCK_FILE"
    if [[ -n "${LND_MACAROON_ROTATION_ID:-}" && \
        ! -f "$LND_DATA/.macaroon-rotated-$LND_MACAROON_ROTATION_ID" ]]; then
        restart_after_password_migration
    fi
}

echo "[initunlocklnd] Waiting 2 seconds for lnd..."
sleep 2

# ensure that lnd is up and running before proceeding
while
    CA_CERT="$LND_DATA/tls.cert"
    LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
    MACAROON_FILE="$LND_DATA/admin.macaroon"
    MACAROON_HEADER="r0ckstar:dev"
    if [ -f "$MACAROON_FILE" ]; then
        MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
    fi

    STATUS_CODE=$(curl -s --cacert "$CA_CERT" -H $MACAROON_HEADER -o /dev/null -w "%{http_code}" $LND_REST_LISTEN_HOST/v1/getinfo)
    # if lnd is running it'll either return 200 if unlocked (noseedbackup=1) or 404 if it needs initialization/unlock 
    if [ "$STATUS_CODE" == "200" ] || [ "$STATUS_CODE" == "404" ] ; then
        break
    # or 500 from version 0.13.1 onwards because it breaks with `wallet not created, create one to enable full RPC access` error
    elif [ "$STATUS_CODE" == "500" ] ; then
        STATUS_CODE=$(curl -s --cacert "$CA_CERT" -H $MACAROON_HEADER $LND_REST_LISTEN_HOST/v1/state)
        if [ "$STATUS_CODE" == "{\"state\":\"NON_EXISTING\"}" ] || [ "$STATUS_CODE" == "{\"state\":\"LOCKED\"}" ] ; then
            break # wallet ready to be either created or unlocked
        fi
        # for {\"state\":\"UNLOCKED\"}" we will depend on that previous condition with STATUS_CODE 200 or 404
        # because even though wallet is unlocked, /v1/getinfo will still keep returning 500 until it's ready

        echo "[initunlocklnd] Still waiting on LND, got response for wallet status: $STATUS_CODE ... waiting another 2 seconds..."
        sleep 2
    else
        echo "[initunlocklnd] LND still didn't start, got $STATUS_CODE status code back... waiting another 2 seconds..."
        sleep 2
    fi
do true; done

# read variables after we ensured that lnd is up
CA_CERT="$LND_DATA/tls.cert"
LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
MACAROON_FILE="$LND_DATA/admin.macaroon"
MACAROON_HEADER="r0ckstar:dev"
if [ -f "$MACAROON_FILE" ]; then
    MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
fi

WALLET_FILE="$LND_WALLET_DIR/wallet.db"
LNDUNLOCK_FILE=${WALLET_FILE/wallet.db/walletunlock.json}
if [ -f "$WALLET_FILE" ]; then
    if [ ! -f "$LNDUNLOCK_FILE" ]; then
        echo "[initunlocklnd] WARNING: UNLOCK FILE DOESN'T EXIST! MIGRATE LEGACY INSTALLATION TO NEW VERSION ASAP"
    else
        echo "[initunlocklnd] Wallet and Unlock files are present... parsing wallet password and unlocking lnd"

        # parse wallet password from unlock file
        WALLETPASS=$(jq -c -r '.wallet_password' $LNDUNLOCK_FILE)
        # Nicolas deleted default password in some wallet unlock files, so we initializing default if password is empty
        if [ "$WALLETPASS" == "" ] || [ "$WALLETPASS" == "null" ]; then
            WALLETPASS="hellorockstar"
        fi
        # Corrected password (removing newlines before encoding).
        # previous versions will have a default wallet password including a line feed at the end "hellorockstar\n"
        # line feed hex code 0x0A. So we first try the password without the line feed if it fails we try it with
        # the older version.
        WALLETPASS_BASE64=$(echo $WALLETPASS | tr -d '\n\r' | base64)

        # Resume a saved attempt before generating another password. A pending
        # replacement may already be the wallet's password after an RPC error
        # or an interruption before the final file update.
        PENDING_EXISTS=$(jq -r 'has("wallet_password_pending")' "$LNDUNLOCK_FILE")
        if [[ "$PENDING_EXISTS" == "true" ]]; then
            if ! jq -e '.wallet_password_pending | type == "string" and length >= 8' \
                "$LNDUNLOCK_FILE" >/dev/null; then
                echo "[initunlocklnd] Invalid pending wallet password; preserving the unlock file for recovery"
                exit 1
            fi
        fi

        MIGRATE_DEFAULT=0
        if [[ "$WALLETPASS" == "hellorockstar" || "$PENDING_EXISTS" == "true" ]]; then
            MIGRATE_DEFAULT=1
        fi

        if [[ $MIGRATE_DEFAULT == 1 ]]; then
            if [[ "$PENDING_EXISTS" == "true" ]]; then
                NEWPASS=$(jq -r '.wallet_password_pending' "$LNDUNLOCK_FILE")
            else
                NEWPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
                if [[ ${#NEWPASS} != 44 ]]; then
                    echo "[initunlocklnd] Could not generate a wallet password; no password change was attempted"
                    exit 1
                fi
                save_unlock_file --arg pw "$NEWPASS" '.wallet_password_pending = $pw'
            fi
            NEWPASS_BASE64=$(printf %s "$NEWPASS" | base64 | tr -d '\n')

            migrated=0
            if [[ "$PENDING_EXISTS" == "true" ]]; then
                if ! pending_response=$(wallet_request unlockwallet \
                    "$(jq -cn --arg pw "$NEWPASS_BASE64" '{wallet_password: $pw}')"); then
                    echo "[initunlocklnd] Pending-password unlock had an uncertain outcome; both passwords remain in $LNDUNLOCK_FILE"
                    exit 1
                fi
                if request_succeeded "$pending_response"; then
                    finish_password_migration
                    migrated=1
                elif ! wrong_wallet_password "$pending_response"; then
                    echo "[initunlocklnd] Pending-password unlock failed: $pending_response"
                    echo "[initunlocklnd] Both passwords remain in $LNDUNLOCK_FILE; migration is not complete"
                    exit 1
                fi
            fi

            if [[ "$migrated" == "0" ]]; then
                if ! rotate_response=$(wallet_request changepassword \
                    "$(jq -cn --arg old "$WALLETPASS_BASE64" --arg new "$NEWPASS_BASE64" \
                        '{current_password: $old, new_password: $new}')"); then
                    echo "[initunlocklnd] Password change had an uncertain outcome; both passwords remain in $LNDUNLOCK_FILE"
                    exit 1
                fi
                if wrong_wallet_password "$rotate_response"; then
                    WALLETPASS_BASE64_CURRENT=$(printf '%s\n' "$WALLETPASS" | base64 | tr -d '\n')
                    if ! rotate_response=$(wallet_request changepassword \
                        "$(jq -cn --arg old "$WALLETPASS_BASE64_CURRENT" --arg new "$NEWPASS_BASE64" \
                            '{current_password: $old, new_password: $new}')"); then
                        echo "[initunlocklnd] Legacy password change had an uncertain outcome; both passwords remain in $LNDUNLOCK_FILE"
                        exit 1
                    fi
                fi

                if request_succeeded "$rotate_response"; then
                    finish_password_migration
                else
                    echo "[initunlocklnd] Password migration failed: $rotate_response"
                    echo "[initunlocklnd] The wallet password may already have changed; both passwords remain in $LNDUNLOCK_FILE"
                    if jq -e '.message == "default root key not found"' \
                        >/dev/null 2>&1 <<< "$rotate_response"; then
                        restart_after_password_migration
                    fi
                    exit 1
                fi
            fi
        else
        response=$(curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" \
            -d '{ "wallet_password":"'$WALLETPASS_BASE64'" }' $LND_REST_LISTEN_HOST/v1/unlockwallet)

        if [[ "$response" == "{}" ]]; then
            echo "[initunlocklnd] Wallet unlocked"
        else
            # If it fails, try the original password with linefeed
            WALLETPASS_BASE64_CURRENT=$(echo $WALLETPASS | base64)

            # Now we change the password so that the line feed is removed.
            # The correct password is already written to the unlock file so we don't need
            # to change that. Moreover the changepassword call will change + unlock the wallet
            # there is no need to call unlockwallet after this call.
            change_password_response=$(curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" \
                -d '{ "current_password":"'$WALLETPASS_BASE64_CURRENT'", "new_password":"'$WALLETPASS_BASE64'" }' \
                $LND_REST_LISTEN_HOST/v1/changepassword)

            if [[ "$change_password_response" == "{}" || "$change_password_response" == *'"admin_macaroon"'* ]]; then
                # make sure the log end with a newline.
                echo -n "[initunlocklnd] Changed wallet password removing the \"line feed\" character at the end. "
                echo "The password can be found in $LNDUNLOCK_FILE"
            else
                echo "[initunlocklnd] Wallet unlocking failed, unlockwallet returned: $response ; changepassword returned: $change_password_response"
                exit 1
            fi
        fi
        fi
    fi
else
    echo "[initunlocklnd] Wallet file doesn't exist. Initializing LND instance with new autogenerated password and seed"

    # generate seed mnemonic
    GENSEED_RESP=$(curl -s --cacert "$CA_CERT" -X GET -H $MACAROON_HEADER $LND_REST_LISTEN_HOST/v1/genseed)
    CIPHER_ARRAY_EXTRACTED=$(echo $GENSEED_RESP | jq -c -r '.cipher_seed_mnemonic')

    # random per-instance password, stored in cleartext in the unlock file next
    # to wallet.db (the file that BTCPay's seed backup view exposes)
    WALLETPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

    # save all the the data to unlock file we'll use for future unlocks
    RESULTJSON='{"wallet_password":"'$WALLETPASS'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'
    mkdir -p $LND_WALLET_DIR
    echo $RESULTJSON > $LNDUNLOCK_FILE

    # previous versions will have a default wallet password including a line feed at the end "hellorockstar\n"
    # line feed hex code 0x0A.
    WALLETPASS_BASE64=$(echo $WALLETPASS | tr -d '\n\r' | base64)
    INITWALLET_REQ='{"wallet_password":"'$WALLETPASS_BASE64'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'

    # execute initwallet call
    curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" -d "$INITWALLET_REQ" $LND_REST_LISTEN_HOST/v1/initwallet
fi

# LND unlocked, now run Loop

if [ ! -z "$LND_HOST_FOR_LOOP" ]; then
    echo "[initunlocklnd] Preparing to start Loop"

    if [ $LND_ENVIRONMENT == "regtest" ] || [ $LND_ENVIRONMENT == "signet" ]; then
        echo "[initunlocklnd] Loop can't be started for regtest and signet"
    elif [ -f "$MACAROON_FILE" ]; then
        sleep 10

        echo "[initunlocklnd] Starting Loop"
        ./bin/loopd --network=$2 --lnd.macaroonpath=$MACAROON_FILE --lnd.host=$LND_HOST_FOR_LOOP --restlisten=0.0.0.0:8081 &
    else
        echo "[initunlocklnd] Loop can't be started without MACAROON"
    fi
fi
