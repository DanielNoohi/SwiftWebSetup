#!/usr/bin/env bats

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

@test "all scripts: CRLF self-heal uses literal tr -d '\\r' on one line" {
	for f in host-install.sh docker-way.sh install.sh; do
		line=$(grep -n "tr -d" "$REPO_ROOT/$f" | head -1)
		echo "$line" | grep -q "tr -d '\\\\r'" || fail "misformatted CRLF self-heal in $f: $line"
	done
}

@test "host-install.sh: source-safe guard present" {
	run grep -q 'BASH_SOURCE.*==.*\$0' "$REPO_ROOT/host-install.sh"
	[ "$status" -eq 0 ]
}

@test "web-install.sh is a wrapper to host-install.sh" {
	grep -q 'host-install.sh' "$REPO_ROOT/web-install.sh"
}

@test "scripts source lib/common.sh" {
	grep -q 'lib/common.sh' "$REPO_ROOT/host-install.sh"
	grep -q 'lib/common.sh' "$REPO_ROOT/docker-way.sh"
}

@test "gen_password: returns exactly N safe chars" {
	source_script lib/common.sh
	run gen_password 32
	[ "$status" -eq 0 ]
	[ ${#output} -eq 32 ]
	[[ "$output" != *'$'* ]] || fail "contains dollar sign"
	[[ "$output" != *"'"* ]] || fail "contains single quote"
}

@test "scrub_secrets: redacts known secrets" {
	source_script lib/common.sh
	WP_DB_PASSWORD='sup3rsecret'
	ADMIN_PASSWORD='admpass'
	MYSQL_ROOT_PASSWORD='rootsecret'
	run scrub_secrets "pass $WP_DB_PASSWORD $ADMIN_PASSWORD $MYSQL_ROOT_PASSWORD"
	[[ "$output" != *sup3rsecret* ]]
	[[ "$output" == *'********'* ]]
}

@test "get_site_url: uses domain when set" {
	source_script lib/common.sh
	DOMAIN='example.com'
	run get_site_url
	[ "$output" = "http://example.com" ]
}

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

@test "common log(): writes to stderr, not stdout" {
	run bash -c "source '$REPO_ROOT/lib/common.sh'; out=\$(info hello 2>/dev/null); echo \"[\$out]\""
	[[ "$output" == "[]" ]]
}

@test "host-install.sh: --force drops WordPress database" {
	grep -q 'DROP DATABASE IF EXISTS' "$REPO_ROOT/host-install.sh"
}

@test "host-install.sh: runs wp as www-data" {
	grep -q 'sudo -u www-data' "$REPO_ROOT/host-install.sh"
}

@test "host-install.sh: credentials saved after verify (save_credentials)" {
	grep -q 'save_credentials' "$REPO_ROOT/host-install.sh"
}

@test "host-install.sh: has --backup-only" {
	grep -q 'backup-only\|BACKUP_ONLY' "$REPO_ROOT/host-install.sh"
}

@test "docker-way.sh: --force uses down -v" {
	grep -q 'down -v' "$REPO_ROOT/docker-way.sh"
}

@test "install.sh: --help exits 0" {
	run bash "$REPO_ROOT/install.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"WordPress Production Bootstrap"* ]]
}

@test "install.sh: calls host-install.sh" {
	grep -q 'host-install.sh' "$REPO_ROOT/install.sh"
}

@test "no LAMP product branding in README" {
	! grep -qiE '\bLAMP\b' "$REPO_ROOT/README.md"
}

@test "collect_site_config exists in common.sh" {
	grep -q 'collect_site_config' "$REPO_ROOT/lib/common.sh"
}
