#!/bin/bash
# Disposable regtest integration tests using the released, unmodified LND binary.
# Run: bash tests/docker-startup.sh (Docker, curl and jq required).
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=btcpayserver/lnd:v0.21.3-beta-1
NAME=btcpay-startup-$$
BTC=$NAME-bitcoin
LND=$NAME-lnd
PEER=$NAME-peer
VOLUME=$NAME-data
WALLET=/data/data/chain/bitcoin/regtest/walletunlock.json
WORK=$(mktemp -d)
cleanup() {
    docker rm -fv "$LND" "$PEER" "$BTC" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo "FAIL ${SCENARIO:-setup} at test line $LINENO" >&2; docker logs --tail 25 "$LND" >&2 || true; docker logs --tail 15 "$PEER" >&2 || true' ERR
wait_for() {
    for ((i=0; i<120; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    docker logs --tail 35 "$LND" >&2 || true
    echo "Timed out waiting for $1" >&2
    return 1
}
bitcoin() { docker exec "$BTC" bitcoin-cli -regtest -rpcuser=test -rpcpassword=test "$@"; }
address() { docker inspect "$LND" | jq -r --arg n "$NAME" '.[0].NetworkSettings.Networks[$n].IPAddress'; }
auth() {
    curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)" "$URL/v1/$1"
}
funded() { auth balance/blockchain | jq -e '.confirmed_balance | tonumber >= 100000000'; }
channel_open() { auth channels | jq -e '.channels | length == 1'; }
channels() { auth channels | jq -Sc '[.channels[] | {channel_point,remote_pubkey,capacity,local_balance,remote_balance}]'; }
peer_info() {
    curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$(docker exec "$PEER" xxd -p -c 10000 /data/admin.macaroon)" "$PEER_URL/v1/getinfo"
}
ready() { docker logs "$LND" 2>&1 | grep -q 'Wallet ready; verified credentials'; }
failed() { docker logs "$LND" 2>&1 | grep -q 'Automatic initialization/unlock stopped'; }
offline() { docker run --rm -i -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c "$1"; }
saved() { docker exec "$LND" cat "$WALLET"; }
count() { offline 'if [ -f /data/launches ]; then wc -l < /data/launches; else echo 0; fi'; }
upgrade() {
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
        -v "$VOLUME:/data" -v "$ROOT/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$ROOT/docker-initunlocklnd.sh:/docker-initunlocklnd.sh:ro" \
        -v "$WORK/count-lnd:/usr/local/bin/lnd:ro" \
        -e LND_CHAIN=btc -e LND_ENVIRONMENT=regtest -e "LND_EXTRA_ARGS=$CONFIG" \
        -e LND_REST_LISTEN_HOST=http://lnd:8080 -e "LND_MACAROON_ROTATION_ID=$ROTATION" "$IMAGE" >/dev/null
    URL=http://$(address):8080
}
# Count execs of the real daemon, including child launches inside a container.
cat > "$WORK/count-lnd" <<'SH'
#!/bin/sh
echo launch >> /data/launches
exec /bin/lnd "$@"
SH
chmod +x "$WORK/count-lnd"
docker network create --internal "$NAME" >/dev/null
docker run -d --name "$BTC" --network "$NAME" --network-alias bitcoin \
    --entrypoint bitcoind btcpayserver/bitcoin:31.1 -regtest -server \
    -fallbackfee=0.0002 \
    -rpcuser=test -rpcpassword=test -rpcbind=0.0.0.0:18443 -rpcallowip=0.0.0.0/0 \
    -listen=0 -zmqpubrawblock=tcp://0.0.0.0:28332 -zmqpubrawtx=tcp://0.0.0.0:28333 >/dev/null
wait_for bitcoin getblockchaininfo
bitcoin createwallet test >/dev/null
bitcoin generatetoaddress 101 "$(bitcoin getnewaddress)" >/dev/null
CONFIG='bitcoin.active=1
bitcoin.regtest=1
bitcoin.node=bitcoind
bitcoind.rpchost=bitcoin:18443
bitcoind.rpcuser=test
bitcoind.rpcpass=test
bitcoind.zmqpubrawblock=tcp://bitcoin:28332
bitcoind.zmqpubrawtx=tcp://bitcoin:28333
restlisten=lnd:8080
no-rest-tls=1
adminmacaroonpath=/data/admin.macaroon
readonlymacaroonpath=/data/readonly.macaroon
invoicemacaroonpath=/data/invoice.macaroon'

for SCENARIO in ${TEST_SCENARIOS:-legacy newline stored-newline empty null omitted password-only custom custom-newline custom-stored-newline pending-before pending-after missing-store-old missing-store-new missing-readonly split-store unknown invalid-json fresh interrupted-init}; do
    echo "Testing $SCENARIO"
    ROTATION=test
    export ACTUAL=hellorockstar STORED=hellorockstar SCENARIO
    case "$SCENARIO" in
        newline) ACTUAL=$'hellorockstar\n' ;;
        stored-newline) ACTUAL=$'hellorockstar\n'; STORED=$ACTUAL ;;
        password-only|split-store) ROTATION= ;;
        custom) ACTUAL=existing-custom-password; STORED=$ACTUAL ;;
        custom-newline) ACTUAL=$'existing-custom-password\n'; STORED=existing-custom-password ;;
        custom-stored-newline) ACTUAL=$'existing-custom-password\n'; STORED=$ACTUAL ;;
        unknown) ACTUAL=unsaved-wallet-password ;;
        interrupted-init) ACTUAL=saved-initialization-password; STORED=$ACTUAL ;;
    esac
    docker volume create "$VOLUME" >/dev/null
    printf '%s\n' "$CONFIG" | offline 'cat > /data/lnd.conf'
    if [[ "$SCENARIO" != fresh ]]; then
        # Fixture setup is separate from the counted upgrade.
        docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
            -v "$VOLUME:/data" --entrypoint /bin/lnd "$IMAGE" --lnddir=/data >/dev/null
        URL=http://$(address):8080
        wait_for curl -sf --max-time 5 "$URL/v1/genseed"
        SEED=$(curl -sf "$URL/v1/genseed")
        export SEED
        jq -nc '{wallet_password:(env.ACTUAL | @base64),cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic)}' |
            curl -sf --data-binary @- "$URL/v1/initwallet" >/dev/null
        wait_for auth getinfo
        IDENTITY=$(auth getinfo | jq -r .identity_pubkey)
        OLD_MACAROON=$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)
        if [[ "$SCENARIO" == password-only ]]; then
            # Verify a funded channel and its backup, not only an empty wallet.
            echo "Creating disposable channel peer"
            printf '%s\n' "${CONFIG/restlisten=lnd/restlisten=peer}" > "$WORK/peer.conf"
            docker create --name "$PEER" --network "$NAME" --network-alias peer \
                --entrypoint /bin/lnd "$IMAGE" --lnddir=/data >/dev/null
            docker cp "$WORK/peer.conf" "$PEER:/data/lnd.conf"
            docker start "$PEER" >/dev/null
            PEER_URL=http://$(docker inspect "$PEER" | jq -r --arg n "$NAME" '.[0].NetworkSettings.Networks[$n].IPAddress'):8080
            wait_for curl -sf --max-time 5 "$PEER_URL/v1/genseed"
            curl -sf "$PEER_URL/v1/genseed" | jq -c '{wallet_password:("disposable-peer-password" | @base64),cipher_seed_mnemonic}' |
                curl -sf --data-binary @- "$PEER_URL/v1/initwallet" >/dev/null
            wait_for peer_info
            echo "Funding disposable channel wallet"
            bitcoin sendtoaddress "$(auth newaddress | jq -r .address)" 1 >/dev/null
            bitcoin generatetoaddress 6 "$(bitcoin getnewaddress)" >/dev/null
            wait_for funded
            PEER_KEY=$(peer_info | jq -r .identity_pubkey)
            echo "Connecting disposable channel peer"
            jq -nc --arg key "$PEER_KEY" '{addr:{pubkey:$key,host:"peer:9735"},perm:true}' |
                curl -sf --max-time 60 -H "Grpc-Metadata-macaroon:$OLD_MACAROON" --data-binary @- "$URL/v1/peers" >/dev/null
            jq -nc --arg key "$PEER_KEY" '{node_pubkey_string:$key,local_funding_amount:"1000000",private:true}' |
                curl -sf --max-time 60 -H "Grpc-Metadata-macaroon:$OLD_MACAROON" --data-binary @- "$URL/v1/channels" >/dev/null
            echo "Confirming disposable channel"
            bitcoin generatetoaddress 6 "$(bitcoin getnewaddress)" >/dev/null
            wait_for channel_open
            CHANNELS=$(channels)
            BACKUP_POINTS=$(auth channels/backup | jq -Sc .multi_chan_backup.chan_points)
        fi
        CUSTOM_MACAROON=$(curl -sf -H "Grpc-Metadata-macaroon:$OLD_MACAROON" \
            -d '{"permissions":[{"entity":"info","action":"read"}],"root_key_id":"7"}' "$URL/v1/macaroon" | jq -er .macaroon)
        BINARY=$(docker exec "$LND" sha256sum /bin/lnd)
        jq -nc '{wallet_password:env.STORED,cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic),unrelated:{keep:true}} |
            if env.SCENARIO == "empty" then .wallet_password="" elif env.SCENARIO == "null" then .wallet_password=null
            elif env.SCENARIO == "omitted" then del(.wallet_password) else . end |
            if (env.SCENARIO | startswith("pending-")) or env.SCENARIO == "missing-store-new" or env.SCENARIO == "split-store"
            then .wallet_password_pending="saved-before-request" else . end' |
            docker exec -i "$LND" sh -c "cat > $WALLET"
        docker stop "$LND" >/dev/null
        if [[ "$SCENARIO" == split-store ]]; then
            offline 'cp /data/data/chain/bitcoin/regtest/macaroons.db /data/old-store'
        fi
        if [[ "$SCENARIO" == pending-after || "$SCENARIO" == missing-store-new || "$SCENARIO" == split-store ]]; then
            docker start "$LND" >/dev/null
            wait_for curl -sf "$URL/v1/state"
            jq -nc '{current_password:(env.ACTUAL | @base64),new_password:("saved-before-request" | @base64)}' |
                curl -sf --data-binary @- "$URL/v1/changepassword" >/dev/null
            wait_for auth getinfo
            docker stop "$LND" >/dev/null
        fi
        docker rm "$LND" >/dev/null
        case "$SCENARIO" in
            missing-store-*) offline 'rm /data/data/chain/bitcoin/regtest/macaroons.db' ;;
            missing-readonly) offline 'rm /data/readonly.macaroon' ;;
            split-store) offline 'mv /data/old-store /data/data/chain/bitcoin/regtest/macaroons.db' ;;
            invalid-json) offline 'printf "{" > /data/data/chain/bitcoin/regtest/walletunlock.json' ;;
            interrupted-init)
                # Keep the real released seed/request, but create a genuinely
                # new volume with the durable initialization record.
                offline "cat $WALLET" > "$WORK/init.json"
                docker volume rm "$VOLUME" >/dev/null
                docker volume create "$VOLUME" >/dev/null
                printf '%s\n' "$CONFIG" | offline 'cat > /data/lnd.conf'
                offline 'mkdir -p /data/data/chain/bitcoin/regtest'
                cat "$WORK/init.json" | offline "cat > $WALLET"
                jq -c '{version:1,password:.wallet_password,old_passwords:[],pending:false,migrate:false,initializing:true,rotation_id:""}' "$WORK/init.json" |
                    offline "cat > $WALLET.recovery" ;;
        esac
        offline 'find /data -type f \( -name "*.db" -o -name "*.macaroon" -o -name "walletunlock.json" \) -exec sha256sum {} \;' > "$WORK/before"
    else
        BINARY=$(docker run --rm --entrypoint sha256sum "$IMAGE" /bin/lnd)
    fi

    upgrade
    case "$SCENARIO" in
        missing-store-*|missing-readonly|invalid-json)
            wait_for failed
            [[ $(count) == 0 ]]
            offline 'find /data -type f \( -name "*.db" -o -name "*.macaroon" -o -name "walletunlock.json" \) -exec sha256sum {} \;' > "$WORK/after"
            diff -u "$WORK/before" "$WORK/after"
            if [[ "$SCENARIO" == invalid-json ]]; then EXPECTED='Invalid metadata'; else EXPECTED='Authentication preparation requires manual recovery'; fi
            docker logs "$LND" 2>&1 | grep -q "$EXPECTED" ;;
        unknown|split-store)
            wait_for failed
            [[ $(count) == 1 ]]
            if [[ "$SCENARIO" == unknown ]]; then
                docker logs "$LND" 2>&1 | grep -q 'none of the saved password candidates'
            else
                docker logs "$LND" 2>&1 | grep -q 'other than the recognized wrong-wallet-password'
                docker exec "$LND" cat "$WALLET.recovery" | jq -e '.password == "saved-before-request" and .pending' >/dev/null
            fi
            [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]]
            [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]] ;;
        *)
            wait_for ready
            wait_for auth getinfo
            [[ $(count) == 1 ]]
            [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]]
            saved | jq -e 'has("wallet_password_pending") | not' >/dev/null
            FINAL=$(saved | jq -r '.wallet_password | @base64')
            if [[ "$SCENARIO" != fresh ]]; then
                [[ $(auth getinfo | jq -r .identity_pubkey) == "$IDENTITY" ]]
                saved | jq -e '.unrelated.keep' >/dev/null
                [[ $(saved | jq -c .cipher_seed_mnemonic) == "$(jq -c .cipher_seed_mnemonic <<< "$SEED")" ]]
                if [[ "$SCENARIO" == custom* ]]; then
                    [[ "$FINAL" == $(printf %s "$ACTUAL" | base64 | tr -d '\n') ]]
                fi
            fi
            if [[ "$SCENARIO" != fresh && "$SCENARIO" != interrupted-init ]]; then
                for TOKEN in "$OLD_MACAROON" "$CUSTOM_MACAROON"; do
                    if [[ "$SCENARIO" == password-only ]]; then
                        curl -sf -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo" >/dev/null
                    else
                        curl -s --max-time 5 -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo" |
                            jq -e '.code != null and (.message | contains("signature mismatch"))' >/dev/null
                    fi
                done
            fi
            if [[ "$SCENARIO" == password-only ]]; then
                [[ $(channels) == "$CHANNELS" ]]
                [[ $(auth channels/backup | jq -Sc .multi_chan_backup.chan_points) == "$BACKUP_POINTS" ]]
            fi
            for FILE in "$WALLET" "$WALLET.recovery"; do
                [[ $(docker exec "$LND" stat -c %a "$FILE") == 600 ]]
            done
            for FILE in admin readonly invoice; do docker exec "$LND" test -s "/data/$FILE.macaroon"; done
            BEFORE_MACAROON=$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)
            # Simulate older BTCPay rewriting stale password data while removing
            # the seed. Recovery must survive and not repeat rotation.
            if [[ "$SCENARIO" == legacy ]]; then
                printf '%s\n' '{"wallet_password":"hellorockstar","cipher_seed_mnemonic":["Seed removed"]}' |
                    docker exec -i "$LND" sh -c "cat > $WALLET"
            fi
            docker stop "$LND" >/dev/null
            docker rm "$LND" >/dev/null
            upgrade
            wait_for ready
            [[ $(count) == 2 ]]
            [[ $(saved | jq -r '.wallet_password | @base64') == "$FINAL" ]]
            curl -sf -H "Grpc-Metadata-macaroon:$BEFORE_MACAROON" "$URL/v1/getinfo" >/dev/null
            if [[ "$SCENARIO" == legacy ]]; then saved | jq -e '.cipher_seed_mnemonic == ["Seed removed"]' >/dev/null; fi ;;
    esac
    [[ $(docker inspect "$LND" | jq -r '.[0].HostConfig.RestartPolicy.Name') == no ]]
    [[ $(docker inspect "$LND" | jq -r '.[0].RestartCount') == 0 ]]
    docker rm -fv "$LND" >/dev/null
    if [[ "$SCENARIO" == password-only ]]; then docker rm -fv "$PEER" >/dev/null; fi
    docker volume rm "$VOLUME" >/dev/null
    echo "PASS $SCENARIO"
done
