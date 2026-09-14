#!/bin/bash
set -euo pipefail
umask 077

log() { echo "[btcpay-lnd] $*" >&2; }
fail() { log "$* Automatic initialization/unlock stopped."; exit 1; }

# Passwords stay encoded or in JSON; command substitution must not trim them.
read_json() {
    [[ -f "$1" && ! -L "$1" && -r "$1" ]] || fail "Filesystem error reading $1."
    jq -ces 'if length == 1 and (.[0] | type == "object") then .[0] else error("object required") end' "$1" \
        2>/dev/null || fail "Invalid metadata at $1."
}
save_json() {
    local file=$1 temporary
    temporary=$(mktemp "$file.tmp.XXXXXX") || return 1
    if ! cat > "$temporary" ||
        ! jq -es 'length == 1 and (.[0] | type == "object")' "$temporary" >/dev/null ||
        ! chmod 600 "$temporary" || ! sync "$temporary" ||
        ! mv -f "$temporary" "$file"; then
        rm -f "$temporary"
        return 1
    fi
    sync "$(dirname "$file")" || return 1
}
save_record() {
    printf '%s\n' "$RECORD" | save_json "$RECOVERY" ||
        fail "Filesystem error saving recovery credentials at $RECOVERY; no further request was sent."
}
post() {
    printf '%s\n' "$1" | curl -sS --max-time 120 --cacert "$CA_CERT" \
        -H 'Content-Type: application/json' --data-binary @- "$LND_REST_LISTEN_HOST/v1/$2"
}
success() {
    jq -es 'length == 1 and (.[0] | type == "object" and (has("code") | not) and
        (. == {} or (.admin_macaroon | type == "string")))' >/dev/null <<< "$1"
}
wrong_password() {
    # This error comes from opening wallet public keys. Other errors do not
    # establish whether the password was accepted or whether it changed.
    jq -es 'length == 1 and (.[0] | (.code == 2) and ((.message // "") |
        test("^(unable to open wallet: )?invalid passphrase for master public key$")))' >/dev/null <<< "$1"
}
manual_auth() {
    fail "Authentication preparation requires manual recovery: $*. Preserve the wallet, seed, channel backup and $RECOVERY. Inspect LND before any offline repair; do not delete a live database."
}
rpc_failed() {
    local message
    message=$(jq -r '.message // empty' <<< "$1" 2>/dev/null || true)
    case "$message" in
        *timeout*|*database\ is\ locked*)
            fail "Database busy or request timed out. Inspect LND's logs; saved credentials are retained at $RECOVERY." ;;
        *permission\ denied*|*read-only\ file\ system*|*no\ space\ left*)
            fail "Filesystem error during the wallet request. Inspect LND's logs; saved credentials are retained at $RECOVERY." ;;
        invalid\ password|*macaroon*|*root\ key*|*could\ not\ create\ unlock*|*could\ not\ change\ password*)
            manual_auth "LND rejected the request for a reason other than the recognized wrong-wallet-password error; the wallet password may already have changed" ;;
        *)
            fail "Unexpected LND response; password acceptance and migration completion are unconfirmed. Inspect LND's logs; saved credentials remain at $RECOVERY." ;;
    esac
}

WALLET_DIR="$LND_DATA/data/chain/$1/$2"
WALLET="$WALLET_DIR/wallet.db"
UNLOCK="$WALLET_DIR/walletunlock.json"
RECOVERY="$UNLOCK.recovery"
CA_CERT="$LND_DATA/tls.cert"
ROTATION=${LND_MACAROON_ROTATION_ID:-}
ROTATE=false
RECORD='null'
METADATA='{}'
MACAROONS=("$WALLET_DIR/admin.macaroon" "$WALLET_DIR/readonly.macaroon" "$WALLET_DIR/invoice.macaroon")

# Fail explicitly for storage overrides rather than inspect a different wallet.
[[ "$LND_DATA" == /* ]] || fail "Unsupported configuration: LND_DATA must be an absolute path."
[[ "$1" == bitcoin && "$2" =~ ^(mainnet|testnet|signet|regtest)$ ]] ||
    fail "Unsupported storage/configuration: expected a Bitcoin network."
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* || "$line" == '[Application Options]' ]] && continue
    [[ "$line" != \[* ]] || fail "Unsupported configuration: use unsectioned LND_EXTRA_ARGS options."
    key=${line%%=*}; key=${key//[[:space:]]/}; key=${key,,}
    value=${line#*=}; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
        lnddir|datadir|configfile|wallet-unlock-password-file|bitcoin.signetchallenge|bitcoin.testnet4|reset-wallet-transactions)
            fail "Unsupported storage/configuration: $key." ;;
        db.backend)
            [[ "$value" == bolt ]] || fail "Unsupported storage: expected db.backend=bolt." ;;
        noseedbackup|no-macaroons|remotesigner.enable|wallet-unlock-allow-create)
            [[ "$value" == 0 || "$value" == false ]] || fail "Unsupported configuration: $key." ;;
        bitcoin.mainnet|bitcoin.testnet|bitcoin.signet|bitcoin.regtest|bitcoin.simnet)
            [[ "$value" == 0 || "$value" == false || "$key" == "bitcoin.$2" ]] ||
                fail "Unsupported configuration: network differs from LND_ENVIRONMENT." ;;
        tlscertpath)
            [[ "$value" == "$CA_CERT" ]] || fail "Unsupported configuration: custom tlscertpath." ;;
        adminmacaroonpath|readonlymacaroonpath|invoicemacaroonpath)
            [[ "$value" == /*.macaroon && "$value" != *'$'* && "$value" != *'~'* && "$value" != *'"'* ]] ||
                fail "Unsupported configuration: $key requires an absolute .macaroon path."
            case "$key" in
                adminmacaroonpath) MACAROONS[0]=$value ;;
                readonlymacaroonpath) MACAROONS[1]=$value ;;
                invoicemacaroonpath) MACAROONS[2]=$value ;;
            esac ;;
    esac
done < "$LND_DATA/lnd.conf"
MACAROON_FILE=${MACAROONS[0]}
for argument in "${@:4}"; do
    [[ "$argument" == lnd || "$argument" == "--lnddir=$LND_DATA" ]] ||
        fail "Unsupported configuration: put daemon options in LND_EXTRA_ARGS."
done
[[ ! -L "$WALLET" && ! -L "$UNLOCK" && ! -L "$RECOVERY" ]] ||
    fail "Unsupported configuration: wallet and credential files must not be symlinks."

if [[ -e "$UNLOCK" ]]; then
    METADATA=$(read_json "$UNLOCK")
    jq -e '(.wallet_password == null or (.wallet_password | type == "string")) and
        ((has("wallet_password_pending") | not) or
        (.wallet_password_pending | type == "string" and length >= 8))' >/dev/null <<< "$METADATA" ||
        fail "Invalid metadata at $UNLOCK: invalid password field."
fi
if [[ -e "$RECOVERY" ]]; then
    RECORD=$(read_json "$RECOVERY")
    jq -e '.version == 1 and (.password | type == "string" and length >= 8 and length <= 4096) and
        (.old_passwords | type == "array" and length <= 4 and all(.[]; type == "string" and length > 0 and length <= 4096)) and
        (.pending | type == "boolean") and (.migrate | type == "boolean") and (.initializing | type == "boolean") and
        (.rotation_id | type == "string") and
        (keys - ["version","password","old_passwords","pending","migrate","initializing","rotation_id"] | length == 0) and
        (.initializing == false or (.pending == false and .migrate == false))' >/dev/null <<< "$RECORD" ||
        fail "Invalid metadata at $RECOVERY: invalid recovery record."
    # Older BTCPay may write stale password data when removing the seed.
    if ! printf '%s\n%s\n' "$METADATA" "$RECORD" | jq -es '
        .[0] as $m | .[1] as $r |
        (($m.wallet_password_pending // $r.password) as $p | $p == $r.password or
        ($r.migrate == false and ($r.old_passwords | index($p) != null))) and
        (($m.wallet_password // "") as $p | $p == "" or $p == $r.password or
        ($r.old_passwords | index($p) != null))' >/dev/null; then
        fail "Invalid metadata: conflicting credentials in $UNLOCK and $RECOVERY; both files were preserved."
    fi
fi
if [[ -n "$ROTATION" ]]; then
    [[ "$ROTATION" =~ ^[a-zA-Z0-9_.-]+$ ]] || fail "Invalid configuration: LND_MACAROON_ROTATION_ID."
    if [[ ! -f "$LND_DATA/.macaroon-rotated-$ROTATION" ]] &&
        ! jq -e --arg id "$ROTATION" '.rotation_id == $id' >/dev/null <<< "$RECORD"; then
        ROTATE=true
    fi
fi

if [[ -f "$WALLET" ]]; then
    [[ -f "$UNLOCK" || "$RECORD" != null ]] ||
        fail "Missing metadata at $UNLOCK; supply the existing wallet's credentials for manual recovery."
    [[ -f "$WALLET_DIR/macaroons.db" && ! -L "$WALLET_DIR/macaroons.db" ]] ||
        manual_auth "macaroons.db is missing or is not a regular file"
    if [[ "$ROTATE" == true ]]; then
        for macaroon in "${MACAROONS[@]}"; do
            [[ -f "$macaroon" && ! -L "$macaroon" ]] ||
                manual_auth "required token file is missing or is not a regular file: $macaroon"
        done
    fi
else
    [[ ! -e "$WALLET" ]] || fail "Filesystem error: $WALLET is not a regular file."
    if [[ "$RECORD" != null ]]; then
        jq -e '.initializing' >/dev/null <<< "$RECORD" ||
            fail "Manual recovery required: wallet.db is missing from an existing installation. No replacement wallet will be created."
    else
        # Only our saved initialization record authorizes resuming a node
        # whose databases were created before InitWallet finished.
        evidence=$(find "$LND_DATA" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.macaroon' -o \
            -name 'channel.backup' -o -name 'lnd.log' -o -name 'walletunlock.json.password-history' \) -print -quit) ||
            fail "Filesystem error inspecting $LND_DATA."
        [[ -z "$evidence" ]] ||
            fail "Manual recovery required: wallet.db is missing but existing node data remains. No replacement seed will be generated."
    fi
    if [[ -f "$UNLOCK" ]]; then
        jq -e '(.wallet_password | type == "string" and length >= 8) and
            (.cipher_seed_mnemonic | type == "array" and length == 24 and all(.[]; type == "string" and test("^[a-z]+$"))) and
            (has("wallet_password_pending") | not)' >/dev/null <<< "$METADATA" ||
            fail "Invalid metadata at $UNLOCK: incomplete initialization request."
    fi
    if printf '%s\n%s\n' "$METADATA" "$RECORD" | jq -es '
        (.[0].wallet_password // .[1].password) | . == "hellorockstar" or . == "hellorockstar\n"' >/dev/null; then
        fail "Manual preparation required: the saved initialization request uses the shared legacy password. Preserve its seed and credentials; do not initialize another wallet with that password."
    fi
fi

# Run synchronously before exec lnd. No database is opened, removed or changed.
if [[ "${3:-}" == --prepare ]]; then
    if [[ ! -f "$WALLET" && "$RECORD" == null ]]; then
        mkdir -p "$WALLET_DIR"
        if [[ -f "$UNLOCK" ]]; then
            INITIAL_PASSWORD=$(jq -r '.wallet_password | @base64' <<< "$METADATA")
        else
            INITIAL_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
            [[ ${#INITIAL_PASSWORD} == 44 ]] || fail "Could not generate an initialization password."
            INITIAL_PASSWORD=$(printf %s "$INITIAL_PASSWORD" | base64 | tr -d '\n')
        fi
        RECORD=$(INITIAL_PASSWORD=$INITIAL_PASSWORD jq -nc '{version:1,
            password:(env.INITIAL_PASSWORD | @base64d),old_passwords:[],
            pending:false,migrate:false,initializing:true,rotation_id:""}')
        save_record
    fi
    exit 0
fi

# Readiness does not prove password acceptance. Launching LND remains solely
# the entrypoint's job; failed requests never launch or restart a daemon.
for ((attempt=0; attempt<120; attempt++)); do
    STATE=$(curl -s --max-time 5 --cacert "$CA_CERT" "$LND_REST_LISTEN_HOST/v1/state" || true)
    STATE=$(jq -r '.state // empty' <<< "$STATE" 2>/dev/null || true)
    [[ "$STATE" == LOCKED || "$STATE" == NON_EXISTING ]] && break
    [[ "$STATE" != RPC_ACTIVE && "$STATE" != SERVER_ACTIVE ]] ||
        fail "Wallet already unlocked before automatic handling; verify the password and requested rotation manually."
    sleep 2
done
[[ "$STATE" == LOCKED || "$STATE" == NON_EXISTING ]] ||
    fail "LND did not become ready. Check its logs for database locking, filesystem or configuration errors."

if [[ "$STATE" == NON_EXISTING ]]; then
    [[ ! -f "$WALLET" ]] || fail "LND reports no wallet but wallet.db exists; inspect storage configuration."
    jq -e '.initializing' >/dev/null <<< "$RECORD" ||
        fail "No saved initialization record; refusing to generate a replacement seed."
    if [[ ! -f "$UNLOCK" ]]; then
        SEED=$(curl -sS --max-time 30 --cacert "$CA_CERT" "$LND_REST_LISTEN_HOST/v1/genseed") ||
            fail "Seed request failed; the saved initialization password is retained."
        jq -e '(.code == null) and (.cipher_seed_mnemonic |
            type == "array" and length == 24 and all(.[]; type == "string" and test("^[a-z]+$")))' >/dev/null <<< "$SEED" ||
            fail "Invalid seed response; no initialization request was sent."
        METADATA=$(printf '%s\n%s\n' "$RECORD" "$SEED" | jq -cs \
            '{wallet_password:.[0].password,cipher_seed_mnemonic:.[1].cipher_seed_mnemonic}')
        printf '%s\n' "$METADATA" | save_json "$UNLOCK" ||
            fail "Filesystem error saving initialization request at $UNLOCK."
    fi
    REQUEST=$(jq -c '{wallet_password:(.wallet_password | @base64),cipher_seed_mnemonic}' <<< "$METADATA")
    RESPONSE=$(post "$REQUEST" initwallet) ||
        fail "Initialization outcome unknown; saved seed and password retained. No request will be repeated on this start."
    success "$RESPONSE" || fail "Initialization rejected; inspect LND's logs. Saved initialization data is retained."
    FINAL_PASSWORD=$(jq -r '.wallet_password | @base64' <<< "$METADATA")
else
    if [[ "$RECORD" == null ]]; then
        RECORD=$(jq -c '
            (.wallet_password // "" | if . == "" then "hellorockstar" else . end) as $old |
            {version:1,old_passwords:[$old,($old + "\n")],
            password:(.wallet_password_pending // $old),
            pending:has("wallet_password_pending"),migrate:has("wallet_password_pending"),initializing:false,rotation_id:""}' <<< "$METADATA")
        if jq -e '.pending == false and (.password == "hellorockstar" or .password == "hellorockstar\n")' >/dev/null <<< "$RECORD"; then
            NEW_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
            [[ ${#NEW_PASSWORD} == 44 ]] || fail "Could not generate a replacement password."
            RECORD=$(NEW_PASSWORD=$NEW_PASSWORD jq -c '.password=env.NEW_PASSWORD | .pending=true | .migrate=true' <<< "$RECORD")
        fi
        save_record
    fi
    # Preserve the attempt's original credentials, even after metadata rewrites.
    CANDIDATES=$(jq -cr '[.password] + .old_passwords | unique[] | @base64' <<< "$RECORD")
    FIRST=$(jq -r '.password | @base64' <<< "$RECORD")
    CANDIDATES=$(printf '%s\n%s\n' "$FIRST" "$CANDIDATES" | awk '!seen[$0]++')
    MIGRATE=$(jq -r '.pending and .migrate' <<< "$RECORD")
    ACCEPTED=false
    while IFS= read -r CURRENT_PASSWORD; do
        ENDPOINT=unlockwallet
        FINAL_PASSWORD=$CURRENT_PASSWORD
        if [[ "$MIGRATE" == true || "$ROTATE" == true ]] &&
            ! jq -e '.initializing' >/dev/null <<< "$RECORD"; then
            # Rotation alone changes the password to itself, preserving custom
            # passwords and their exact newline bytes.
            ENDPOINT=changepassword
            if [[ "$MIGRATE" == true ]]; then FINAL_PASSWORD=$FIRST; fi
            RECORD=$(FINAL_PASSWORD=$FINAL_PASSWORD jq -c '.password=(env.FINAL_PASSWORD | @base64d) | .pending=true' <<< "$RECORD")
            save_record
            CURRENT_METADATA=$(read_json "$UNLOCK")
            printf '%s\n%s\n' "$CURRENT_METADATA" "$RECORD" | jq -cs '.[0] + {wallet_password_pending:.[1].password}' |
                save_json "$UNLOCK" || fail "Filesystem error saving pending state at $UNLOCK."
        fi
        REQUEST=$(CURRENT_PASSWORD=$CURRENT_PASSWORD FINAL_PASSWORD=$FINAL_PASSWORD ROTATE=$ROTATE ENDPOINT=$ENDPOINT jq -nc '
            if env.ENDPOINT == "changepassword" then
                {current_password:env.CURRENT_PASSWORD,new_password:env.FINAL_PASSWORD,
                 new_macaroon_root_key:(env.ROTATE == "true")}
            else {wallet_password:env.CURRENT_PASSWORD} end')
        RESPONSE=$(post "$REQUEST" "$ENDPOINT") ||
            fail "Request outcome unknown; saved passwords retained at $RECOVERY. Inspect LND before manual recovery."
        if success "$RESPONSE"; then ACCEPTED=true; break; fi
        wrong_password "$RESPONSE" || rpc_failed "$RESPONSE"
    done <<< "$CANDIDATES"
    [[ "$ACCEPTED" == true ]] ||
        fail "Manual recovery required: none of the saved password candidates unlocked this wallet. Preserve your existing LND data, seed and channel backup. Recovery information: https://github.com/btcpayserver/btcpayserver-docker/issues/1112#issuecomment-5659154559"
fi

# RPC success can precede token creation. Confirm authenticated startup before
# recording completion; never require another daemon start to finish migration.
for ((attempt=0; attempt<120; attempt++)); do
    if [[ -s "$MACAROON_FILE" ]]; then
        HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' \n')"
        if curl -sf --max-time 5 --cacert "$CA_CERT" -H "$HEADER" "$LND_REST_LISTEN_HOST/v1/getinfo" >/dev/null; then break; fi
    fi
    sleep 2
done
[[ $attempt -lt 120 ]] ||
    fail "Wallet request accepted, but authenticated startup did not finish. Saved credentials are retained; inspect LND's logs."

# Flush LND's resulting authentication files before our completion record.
sync "$WALLET" "$WALLET_DIR/macaroons.db" "${MACAROONS[@]}" ||
    fail "Filesystem error synchronizing wallet/authentication data; completion was not recorded."

RECORD=$(FINAL_PASSWORD=$FINAL_PASSWORD ROTATION=$ROTATION jq -c '
    .password=(env.FINAL_PASSWORD | @base64d) | .pending=false | .initializing=false |
    if env.ROTATION != "" then .rotation_id=env.ROTATION else . end' <<< "$RECORD")
# Save independently before metadata promotion. Re-read to retain seed removal
# and unrelated fields written by BTCPay while the RPC was in progress.
save_record
if [[ -f "$UNLOCK" ]]; then
    CURRENT_METADATA=$(read_json "$UNLOCK")
    printf '%s\n%s\n' "$CURRENT_METADATA" "$RECORD" | jq -cs \
        '.[0] + {wallet_password:.[1].password} | del(.wallet_password_pending)' |
        save_json "$UNLOCK" || fail "Filesystem error updating $UNLOCK; verified credentials remain in $RECOVERY."
fi
log "Wallet ready; verified credentials saved at $RECOVERY."
[[ "$ROTATE" != true ]] || log "Macaroon rotation complete. All previous root IDs are revoked; clients must obtain new macaroons."

if [[ -n "${LND_HOST_FOR_LOOP:-}" ]]; then
    if [[ "$2" == regtest || "$2" == signet ]]; then
        log "Loop cannot be started for $2."
    else
        sleep 10
        ./bin/loopd --network="$2" --lnd.macaroonpath="$MACAROON_FILE" --lnd.host="$LND_HOST_FOR_LOOP" --restlisten=0.0.0.0:8081 &
    fi
fi
