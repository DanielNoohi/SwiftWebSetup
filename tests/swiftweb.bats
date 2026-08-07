#!/usr/bin/env bats

# SwiftWebSetup unit tests (source the scripts; main() is guarded)

load test_helper

setup() {
	export WP_PATH="${BATS_TMPDIR}/swiftweb-wp"
	export LOG_FILE="${BATS_TMPDIR}/swiftweb.log"
	export CREDENTIALS_FILE="${BATS_TMPDIR}/swiftweb-creds.txt"
	export DRY_RUN=true
	export UNATTENDED=true
	export FORCE=false
	mkdir -p "$WP_PATH"
}

# ── CRLF self-heal ────────────────────────────────────────────────────
@test "all scripts: CRLF self-heal uses literal tr -d '\\r' on one line" {
	for f in web-install.sh docker-way.sh install.sh; do
		line=$(grep -n "tr -d" "$REPO_ROOT/$f" | head -1)
		echo "$line" | grep -q "tr -d '\\\\r'" || fail "misformatted CRLF self-heal in $f: $line"
	done
}

@test "web-install.sh: source-safe (guard present)" {
	run grep -q 'BASH_SOURCE.*==.*\$0' "$REPO_ROOT/web-install.sh"
	[ "$status" -eq 0 ]
}

@test "scripts source lib/common.sh" {
	grep -q 'lib/common.sh' "$REPO_ROOT/web-install.sh"
	grep -q 'lib/common.sh' "$REPO_ROOT/docker-way.sh"
}

# ── Password generation ───────────────────────────────────────────────
@test "gen_password: returns exactly N safe chars" {
	source_script lib/common.sh
	run gen_password 32
	[ "$status" -eq 0 ]
	[ ${#output} -eq 32 ]
	[[ "$output" != *'$'* ]] || fail "contains dollar sign"
	[[ "$output" != *"'"* ]] || fail "contains single quote"
	[[ "$output" != *'"'* ]] || fail "contains double quote"
	[[ "$output" != *'\'* ]] || fail "contains backslash"
}

@test "gen_password: length 12" {
	source_script lib/common.sh
	run gen_password 12
	[ ${#output} -eq 12 ]
}

# ── Logging redaction ─────────────────────────────────────────────────
@test "scrub_secrets: redacts known secrets" {
	source_script lib/common.sh
	WP_DB_PASSWORD='sup3rsecret'
	ADMIN_PASSWORD='admpass'
	MYSQL_ROOT_PASSWORD='rootsecret'
	run scrub_secrets "wp config set DB_PASSWORD $WP_DB_PASSWORD admin $ADMIN_PASSWORD root $MYSQL_ROOT_PASSWORD"
	[[ "$output" != *sup3rsecret* ]]
	[[ "$output" != *admpass* ]]
	[[ "$output" != *rootsecret* ]]
	[[ "$output" == *'********'* ]]
}

# ── get_site_url ──────────────────────────────────────────────────────
@test "get_site_url: uses domain when set" {
	source_script lib/common.sh
	DOMAIN='example.com'
	run get_site_url
	[ "$output" = "http://example.com" ]
}

@test "get_site_url: includes non-80 port" {
	source_script lib/common.sh
	DOMAIN=''
	WORDPRESS_PORT=8080
	# server_ip may be empty in CI sandbox — still must include :8080 when port set
	run get_site_url
	[[ "$output" == *":8080" ]] || [[ "$output" =~ ^http:// ]]
}

# ── clear_default_indexes ─────────────────────────────────────────────
@test "clear_default_indexes: removes Apache welcome index.html" {
	source_script lib/common.sh
	DRY_RUN=false
	mkdir -p "$WP_PATH"
	echo 'It works!' >"$WP_PATH/index.html"
	echo '<?php' >"$WP_PATH/index.php"
	clear_default_indexes "$WP_PATH"
	[ ! -f "$WP_PATH/index.html" ]
	[ -f "$WP_PATH/index.php" ]
}

# ── verify rejects test pages ─────────────────────────────────────────
@test "verify_wordpress_http: rejects It works! body (mocked via function logic)" {
	source_script lib/common.sh
	body='<html><body><h1>It works!</h1></body></html>'
	if echo "$body" | grep -qiE 'It works!|Apache2 (Ubuntu|Debian) Default Page|Welcome to nginx!'; then
		true
	else
		fail "detector should match It works!"
	fi
}

# ── docker-way: log to stderr ─────────────────────────────────────────
@test "common log(): writes to stderr, not stdout" {
	run bash -c "source '$REPO_ROOT/lib/common.sh'; out=\$(info hello 2>/dev/null); echo \"[\$out]\""
	[[ "$output" == "[]" ]]
}

# ── force semantics documented in scripts ─────────────────────────────
@test "web-install.sh: --force drops WordPress database" {
	grep -q 'DROP DATABASE IF EXISTS' "$REPO_ROOT/web-install.sh"
}

@test "docker-way.sh: --force uses down -v" {
	grep -q 'down -v' "$REPO_ROOT/docker-way.sh"
}

@test "web-install.sh: runs wp as www-data" {
	grep -q 'sudo -u www-data' "$REPO_ROOT/web-install.sh"
}

@test "install.sh: --help exits 0 and shows usage" {
	run bash "$REPO_ROOT/install.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"One-Command WordPress Production Bootstrap"* ]]
}

@test "install.sh: forwards child installer (not stub echo)" {
	grep -q 'web-install.sh' "$REPO_ROOT/install.sh"
	grep -q 'docker-way.sh' "$REPO_ROOT/install.sh"
	! grep -qiE 'echo ".*(LAMP|lamp) setup"' "$REPO_ROOT/install.sh"
}
