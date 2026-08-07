#!/usr/bin/env bats

# SwiftWebSetup unit tests (source the scripts, test helpers — main() is guarded)

load test_helper

setup() {
    # point state at a temp dir so tests never touch the real system
    export WP_PATH="${BATS_TMPDIR}/swiftweb-wp"
    export LOG_FILE="${BATS_TMPDIR}/swiftweb.log"
    export CREDENTIALS_FILE="${BATS_TMPDIR}/swiftweb-creds.txt"
    export DRY_RUN=true
    export UNATTENDED=true
    export FORCE=false
    mkdir -p "$WP_PATH"
}

# ── CRLF self-heal ────────────────────────────────────────────────────
@test "web-install.sh: CRLF self-heal uses literal tr -d '\r'" {
    source_script web-install.sh
    run grep -q "tr -d '\\\\r'" web-install.sh
    [ "$status" -eq 0 ]
}

@test "all scripts: CRLF self-heal is a single line (not split)" {
    for f in web-install.sh docker-way.sh install.sh; do
        line=$(grep "tr -d" "$f")
        echo "$line" | grep -q "tr -d .\\\\r." || fail "misformatted CRLF self-heal in $f"
    done
}

@test "web-install.sh: source-safe (guard present)" {
    source_script web-install.sh
    run grep -q 'BASH_SOURCE.*==.*\$0' web-install.sh
    [ "$status" -eq 0 ]
}

# ── Password generation ───────────────────────────────────────────────
@test "gen_password: returns exactly N safe chars" {
    source_script web-install.sh
    run gen_password 32
    [ "$status" -eq 0 ]
    [ ${#output} -eq 32 ]
    # must not contain shell/SQL-breaking chars
    [[ "$output" != *'$'* ]] || fail "contains dollar sign"
    [[ "$output" != *"'"* ]] || fail "contains single quote"
    [[ "$output" != *'"'* ]] || fail "contains double quote"
    [[ "$output" != *'\'* ]] || fail "contains backslash"
}

@test "gen_password: deterministic length 12" {
    source_script web-install.sh
    run gen_password 12
    [ ${#output} -eq 12 ]
}

# ── Logging redaction ─────────────────────────────────────────────────
@test "log_cmd: redacts known secrets" {
    source_script web-install.sh
    # log_cmd writes to $LOG_FILE (repointed after source to a temp file)
    export BATS_LOG="$BATS_TMPDIR/redact.log"  # not used; keep LOG_FILE temp below
    LOG_FILE="$BATS_TMPDIR/secrets.log"
    WP_DB_PASSWORD='sup3rsecret'
    ADMIN_PASSWORD='admpass'
    MYSQL_ROOT_PASSWORD='rootsecret'
    log_cmd "wp config set DB_PASSWORD $WP_DB_PASSWORD admin $ADMIN_PASSWORD root $MYSQL_ROOT_PASSWORD"
    # the log must NOT contain the literal secrets
    ! grep -q 'sup3rsecret' "$LOG_FILE"
    ! grep -q 'admpass' "$LOG_FILE"
    ! grep -q 'rootsecret' "$LOG_FILE"
    # but must contain the redacted marker
    grep -q '********' "$LOG_FILE"
}

# ── get_site_url ──────────────────────────────────────────────────────
@test "get_site_url: uses domain when set" {
    source_script web-install.sh
    DOMAIN='example.com'
    run get_site_url
    [ "$output" = "http://example.com" ]
}

@test "get_site_url: uses IP when no domain" {
    source_script web-install.sh
    DOMAIN=''
    run get_site_url
    [[ "$output" =~ ^http://[0-9.]+$ ]] || [[ "$output" == "http://" ]] && true
}

# ── docker-way.sh: compose_dir is a clean path (stdout only) ─────────
@test "docker-way.sh: log() writes to stderr, not stdout" {
    source_script docker-way.sh
    run bash -c 'source docker-way.sh; out="$(info hello 2>/dev/null)"; echo "[$out]"'
    # info must not print to stdout (would pollute compose_dir capture)
    [[ "$output" == "[]" ]]
}

# ── arg parsing ───────────────────────────────────────────────────────
@test "install.sh: --help exits 0 and shows usage" {
    run bash install.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"One-Command WordPress Production Bootstrap"* ]]
}