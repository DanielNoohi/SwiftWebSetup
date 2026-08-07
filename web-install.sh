write_vhost() {
    backup_dir /etc/apache2/sites-available 2>/dev/null || true
    local vhost="/etc/apache2/sites-available/000-default.conf"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Write Apache vhost to $vhost"
        return 0
    fi
    info "Writing Apache vhost..."
    # Expand DOMAIN, keep ${APACHE_LOG_DIR} literal (unquoted)
    cat > "$vhost" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAdmin webmaster@localhost
    DocumentRoot $WP_PATH
    <Directory $WP_PATH>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    run_cmd a2ensite 000-default >/dev/null 2>&1 || true
    run_cmd systemctl reload apache2
}