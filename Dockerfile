# ==========================================================
# Stage 1: PHP Extensions Builder
# ==========================================================

FROM php:8.2-fpm-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libzip-dev \
    oniguruma-dev \
    icu-dev \
    $PHPIZE_DEPS

# Configure and install PHP extensions
RUN docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd \
        mysqli \
        pdo \
        pdo_mysql \
        mbstring \
        zip \
        intl


# ==========================================================
# Stage 2: Production Image
# ==========================================================

FROM php:8.2-fpm-alpine

# Install runtime dependencies
RUN apk add --no-cache \
    apache2 \
    apache2-proxy \
    apache2-ssl \
    supervisor \
    curl \
    mysql-client \
    libpng \
    libjpeg-turbo \
    freetype \
    libzip \
    icu-libs \
    oniguruma

# Copy PHP extensions from builder
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d

# Create required directories
RUN mkdir -p \
    /var/www/html \
    /run/apache2 \
    /var/log/apache2 \
    /var/log/php-fpm \
    /etc/supervisor/conf.d

# Copy application
COPY . /var/www/html/

# Configure PHP
RUN printf "upload_max_filesize=100M\npost_max_size=100M\n" \
    > /usr/local/etc/php/conf.d/uploads.ini

# Configure PHP-FPM socket
RUN sed -i 's|^listen = .*|listen = /run/php-fpm.sock|' \
    /usr/local/etc/php-fpm.d/www.conf

# Configure Apache
RUN sed -i \
    -e 's/^Listen 80/Listen 80/' \
    -e 's|^DocumentRoot ".*"|DocumentRoot "/var/www/html"|' \
    /etc/apache2/httpd.conf

# Enable Apache modules
RUN sed -i \
    -e 's/^#LoadModule proxy_module/LoadModule proxy_module/' \
    -e 's/^#LoadModule proxy_fcgi_module/LoadModule proxy_fcgi_module/' \
    -e 's/^#LoadModule rewrite_module/LoadModule rewrite_module/' \
    /etc/apache2/httpd.conf

# Apache PHP-FPM configuration
RUN cat <<'EOF' > /etc/apache2/conf.d/php-fpm.conf
<IfModule proxy_fcgi_module>
    ProxyPreserveHost On

    ProxyPassMatch "^/(.*\.php(/.*)?)$" \
        "unix:/run/php-fpm.sock|fcgi://localhost/var/www/html/"
</IfModule>

<Directory "/var/www/html">
    AllowOverride All
    Require all granted
    DirectoryIndex index.php index.html
</Directory>
EOF

# Supervisor configuration
RUN cat <<'EOF' > /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root

[program:php-fpm]
command=/usr/local/sbin/php-fpm --nodaemonize
autostart=true
autorestart=true
priority=10

[program:apache2]
command=/usr/sbin/httpd -DFOREGROUND
autostart=true
autorestart=true
priority=20
EOF

# Set permissions
RUN chown -R www-data:www-data /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \;

# Health check
HEALTHCHECK --interval=30s \
    --timeout=10s \
    --start-period=10s \
    --retries=3 \
    CMD curl -f http://localhost/health.php || exit 1

# Expose HTTP
EXPOSE 80

# Start Supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
