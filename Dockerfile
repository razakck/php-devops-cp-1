# Multi-stage build for PHP application
FROM php:8.2-fpm-alpine AS builder

# Install system dependencies and PHP extensions
RUN apk add --no-cache \
    curl \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    mysql-client \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd mysqli pdo pdo_mysql

# Production stage
FROM php:8.2-fpm-alpine

# Install Apache and required modules
RUN apk add --no-cache \
    apache2 \
    apache2-mod-rewrite \
    apache2-mod-proxy-fcgi \
    supervisor \
    curl \
    mysql-client

# Install PHP extensions from builder stage
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d

# Create Apache user and set directories
RUN mkdir -p /var/www/html /var/run/apache2 /var/log/apache2 \
    && chown -R apache:apache /var/www/html

# Copy application files
COPY . /var/www/html/

# Copy PHP configuration
RUN echo "upload_max_filesize = 100M\npost_max_size = 100M" >> /usr/local/etc/php/conf.d/uploads.ini

# Apache configuration for PHP-FPM
COPY --chown=root:root <<EOF /etc/apache2/conf.d/php-fpm.conf
ProxyPreserveHost On
ProxyPassMatch ^/(.*\.php(/.*)?)$ unix:/run/php-fpm.sock|fcgi://localhost/var/www/html
ProxyPassReverse / unix:/run/php-fpm.sock|fcgi://localhost/var/www/html
EOF

# Enable Apache modules
RUN sed -i 's/^#LoadModule proxy_fcgi_module/LoadModule proxy_fcgi_module/' /etc/apache2/httpd.conf && \
    sed -i 's/^#LoadModule rewrite_module/LoadModule rewrite_module/' /etc/apache2/httpd.conf && \
    sed -i 's/^#LoadModule ssl_module/LoadModule ssl_module/' /etc/apache2/httpd.conf

# Supervisor configuration for process management
COPY --chown=root:root <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root

[program:php-fpm]
command=/usr/local/sbin/php-fpm --nodaemonize
autostart=true
autorestart=true
stderr_logfile=/var/log/php-fpm.log
stdout_logfile=/var/log/php-fpm.log

[program:apache2]
command=/usr/sbin/httpd -DFOREGROUND
autostart=true
autorestart=true
stderr_logfile=/var/log/apache2/error.log
stdout_logfile=/var/log/apache2/access.log
EOF

# Set permissions
RUN chown -R apache:apache /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \; \
    && chmod +x /var/www/html/scripts/*.sh 2>/dev/null || true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health.php || exit 1

# Expose port
EXPOSE 80 443

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]