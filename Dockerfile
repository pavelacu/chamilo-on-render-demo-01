# =========================
# Stage 1: deps (PHP 7.4 CLI + Composer)
# =========================
FROM php:7.4-cli AS deps

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# Tools for Composer and zip support
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends git unzip curl libzip-dev zlib1g-dev; \
  docker-php-ext-install -j"$(nproc)" zip; \
  rm -rf /var/lib/apt/lists/*

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
  --install-dir=/usr/local/bin --filename=composer

# Copy Chamilo from repo (folder 'chamilo/')
COPY chamilo/ /app/

# Install PHP deps (ignore some ext reqs in CLI; runtime will have them)
RUN set -eux; \
  composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader \
    --ignore-platform-req=ext-gd \
    --ignore-platform-req=ext-intl \
    --ignore-platform-req=ext-soap; \
  test -f /app/vendor/autoload.php

# =========================
# Stage 2: runtime (Apache + PHP 7.4)
# =========================
FROM php:7.4-apache

ENV DEBIAN_FRONTEND=noninteractive

# System libs and PHP extensions needed by Chamilo
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    build-essential autoconf pkg-config \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev zlib1g-dev \
    libicu-dev libxml2-dev libonig-dev \
    default-mysql-client; \
  rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  docker-php-ext-configure gd --with-freetype --with-jpeg; \
  docker-php-ext-install -j"$(nproc)" gd mysqli pdo_mysql zip intl mbstring opcache soap

# (Optional) trim toolchain
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# Copy code + vendor from deps stage
COPY --from=deps /app/ /var/www/html/

# Apache: rewrite + headers, AllowOverride, FollowSymLinks, ServerName, forwarded headers
RUN set -eux; \
  a2enmod rewrite headers; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n  Options +FollowSymLinks\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\nServerName ${SERVER_NAME:-localhost}\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex; \
  printf "SetEnvIf X-Forwarded-Proto \"^https$\" HTTPS=on\n" > /etc/apache2/conf-available/forwarded.conf; \
  a2enconf forwarded; \
  printf "RequestHeader set X-Forwarded-Port 443\n" > /etc/apache2/conf-available/forwarded-port.conf; \
  a2enconf forwarded-port; \
  printf "RequestHeader set X-Forwarded-Proto https\n" > /etc/apache2/conf-available/force-https.conf; \
  a2enconf force-https

# Bootstrap PHP so Chamilo never appends the internal port; always see HTTPS:443 behind Render
RUN printf "<?php \$_SERVER['HTTPS']='on'; \$_SERVER['SERVER_PORT']=443; ?>" > /var/www/html/.render_bootstrap.php \
 && echo "auto_prepend_file=/var/www/html/.render_bootstrap.php" > /usr/local/etc/php/conf.d/zz-render-bootstrap.ini

# Startup script: persistence (Disk), perms, create test course, hardening, port
RUN printf '#!/bin/sh\nset -e\n'\
'PORT=${PORT:-80}\n'\
'DATA_DIR=${CHAMILO_DATA:-/var/www/chamilo-data}\n'\
'umask 0002\n'\
'\n'\
'# Ensure app/ is NOT a legacy symlink from older deploys\n'\
'if [ -L /var/www/html/app ]; then\n'\
'  echo "[INFO] Removing legacy symlink /var/www/html/app to restore code dir";\n'\
'  rm -f /var/www/html/app; mkdir -p /var/www/html/app;\n'\
'fi\n'\
'\n'\
'# Writable, persistent directories\n'\
'PERSIST_DIRS="app/config app/cache app/logs web courses archive home temp upload main/default_course_document/images main/lang"\n'\
'\n'\
'if grep -qs " $DATA_DIR " /proc/mounts; then\n'\
'  echo "[INFO] Persistent disk detected at $DATA_DIR";\n'\
'  for d in $PERSIST_DIRS; do\n'\
'    SRC="/var/www/html/$d"; DST="$DATA_DIR/$d"; mkdir -p "$DST";\n'\
'    if [ -e "$SRC" ] && [ ! -L "$SRC" ]; then\n'\
'      if [ -d "$SRC" ]; then\n'\
'        # move contents if any, then remove source to guarantee symlink\n'\
'        find "$SRC" -mindepth 1 -maxdepth 1 -exec mv -f {} "$DST"/ \\; 2>/dev/null || true;\n'\
'      fi;\n'\
'      rm -rf "$SRC";\n'\
'    fi;\n'\
'    [ -L "$SRC" ] || ln -s "$DST" "$SRC";\n'\
'  done;\n'\
'  # Perms on Disk (looser for installer)\n'\
'  chown -R www-data:www-data "$DATA_DIR";\n'\
'  chmod -R 775 "$DATA_DIR"/app "$DATA_DIR"/web "$DATA_DIR"/courses "$DATA_DIR"/archive "$DATA_DIR"/home "$DATA_DIR"/temp "$DATA_DIR"/upload "$DATA_DIR"/main "$DATA_DIR"/app/cache "$DATA_DIR"/app/logs 2>/dev/null || true;\n'\
'  chmod -R 0777 "$DATA_DIR/web" "$DATA_DIR/main/default_course_document/images" "$DATA_DIR/courses" 2>/dev/null || true;\n'\
'  # Also ensure docroot paths (in case installer checks literal path, not symlink)\n'\
'  chmod -R 0777 "/var/www/html/web" "/var/www/html/main/default_course_document/images" "/var/www/html/courses" 2>/dev/null || true;\n'\
'else\n'\
'  if [ "${ALLOW_EPHEMERAL:-}" = "1" ]; then\n'\
'    echo "[WARN] No persistent disk mounted at $DATA_DIR. Running EPHEMERAL (data will be lost).";\n'\
'    for d in $PERSIST_DIRS; do mkdir -p "/var/www/html/$d"; done;\n'\
'    chown -R www-data:www-data /var/www/html/app /var/www/html/web /var/www/html/main /var/www/html/courses /var/www/html/archive /var/www/html/home /var/www/html/temp /var/www/html/upload;\n'\
'    chmod -R 775 /var/www/html/app /var/www/html/web /var/www/html/main /var/www/html/courses /var/www/html/archive /var/www/html/home /var/www/html/temp /var/www/html/upload;\n'\
'    chmod -R 0777 /var/www/html/web /var/www/html/main/default_course_document/images /var/www/html/courses 2>/dev/null || true;\n'\
'  else\n'\
'    echo "[ERROR] No persistent disk mounted at $DATA_DIR. Attach a Disk or set ALLOW_EPHEMERAL=1." >&2; exit 1;\n'\
'  fi;\n'\
'fi\n'\
'\n'\
'# Make sure app/ is writable during install\n'\
'chown www-data:www-data /var/www/html/app || true\n'\
'chmod 775 /var/www/html/app || true\n'\
'\n'\
'# --- Ensure test course exists and is HTTP-served ---\n'\
'mkdir -p "$DATA_DIR/courses/__XxTestxX__";\n'\
'if [ ! -f "$DATA_DIR/courses/__XxTestxX__/test.html" ]; then\n'\
'  echo "<html><body>OK</body></html>" > "$DATA_DIR/courses/__XxTestxX__/test.html";\n'\
'fi\n'\
'chmod -R 0777 "$DATA_DIR/courses/__XxTestxX__" 2>/dev/null || true;\n'\
'chmod -R 0777 "/var/www/html/courses/__XxTestxX__" 2>/dev/null || true;\n'\
'# ---------------------------------------------------\n'\
'\n'\
'# Post-install hardening (only if config exists on Disk)\n'\
'if [ -f "$DATA_DIR/app/config/configuration.php" ]; then\n'\
'  chmod -R 0555 "$DATA_DIR/app/config" 2>/dev/null || true\n'\
'  rm -rf /var/www/html/main/install 2>/dev/null || true\n'\
'fi\n'\
'\n'\
'# Make Apache listen on Render-assigned port\n'\
'sed -ri "s/^Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf || true\n'\
'sed -ri "s/:80>/:${PORT}>/" /etc/apache2/sites-available/000-default.conf || true\n'\
'exec apache2-foreground\n' > /usr/local/bin/run-apache.sh \
 && chmod +x /usr/local/bin/run-apache.sh

# PHP settings (recommended + align installer suggestions)
RUN set -eux; { \
  echo "upload_max_filesize=64M"; \
  echo "post_max_size=64M"; \
  echo "memory_limit=512M"; \
  echo "max_execution_time=300"; \
  echo "display_errors=Off"; \
  echo "short_open_tag=Off"; \
  echo "session.cookie_httponly=On"; \
} > /usr/local/etc/php/conf.d/chamilo.ini

EXPOSE 80
CMD ["run-apache.sh"]