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
# Se reemplaza default-mysql-client por postgresql-client
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    build-essential autoconf pkg-config \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev zlib1g-dev \
    libicu-dev libxml2-dev libonig-dev \
    postgresql-client; \
  rm -rf /var/lib/apt/lists/*

# Core PHP extensions
# Se reemplazan las extensiones de MySQL por las de PostgreSQL (pdo_pgsql y pgsql)
RUN set -eux; \
  docker-php-ext-configure gd --with-freetype --with-jpeg; \
  docker-php-ext-install -j"$(nproc)" gd pdo_pgsql pgsql zip intl mbstring opcache soap

# APCu from PECL (for PHP 7.4)
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
  pecl install apcu-5.1.22; \
  docker-php-ext-enable apcu; \
  { \
    echo "apc.enabled=1"; \
    echo "apc.shm_size=64M"; \
    echo "apc.enable_cli=0"; \
    echo "apc.use_request_time=1"; \
  } > /usr/local/etc/php/conf.d/apcu.ini; \
  apt-get purge -y --auto-remove $PHPIZE_DEPS; \
  rm -rf /var/lib/apt/lists/*

# (Optional) trim toolchain
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# Copy code + vendor from deps stage
COPY --from=deps /app/ /var/www/html/

# ---- Keep a baseline copy of static assets inside the image ----
RUN set -eux; \
  mkdir -p /opt/chamilo-defaults/web /opt/chamilo-defaults/main/default_course_document/images; \
  if [ -d /var/www/html/web ]; then cp -a /var/www/html/web/. /opt/chamilo-defaults/web/; fi; \
  if [ -d /var/www/html/main/default_course_document/images ]; then cp -a /var/www/html/main/default_course_document/images/. /opt/chamilo-defaults/main/default_course_document/images/; fi
# ----------------------------------------------------------------

# Apache: rewrite + headers + mime, AllowOverride, FollowSymLinks, ServerName, forwarded headers, alias /courses
RUN set -eux; \
  a2enmod rewrite headers mime alias; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n  Options +FollowSymLinks\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\nServerName ${SERVER_NAME:-localhost}\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex; \
  printf "SetEnvIf X-Forwarded-Proto \"^https$\" HTTPS=on\n" > /etc/apache2/conf-available/forwarded.conf; \
  a2enconf forwarded; \
  printf "RequestHeader set X-Forwarded-Port 443\n" > /etc/apache2/conf-available/forwarded-port.conf; \
  a2enconf forwarded-port; \
  printf "RequestHeader set X-Forwarded-Proto https\n" > /etc/apache2/conf-available/force-https.conf; \
  a2enconf force-https; \
  printf 'Alias /courses/ "/var/www/chamilo-data/courses/"\n<Directory "/var/www/chamilo-data/courses">\n  Options +Indexes +FollowSymLinks\n  Require all granted\n  SetHandler None\n</Directory>\n' > /etc/apache2/conf-available/courses-alias.conf; \
  a2enconf courses-alias

# Bootstrap PHP so Chamilo never appends the internal port; always see HTTPS:443 behind Render
RUN printf "<?php \$_SERVER['HTTPS']='on'; \$_SERVER['SERVER_PORT']=443; ?>" > /var/www/html/.render_bootstrap.php \
 && echo "auto_prepend_file=/var/www/html/.render_bootstrap.php" > /usr/local/etc/php/conf.d/zz-render-bootstrap.ini

# Startup script: persistence (Disk), perms, repopulate assets, force symlinks, test course, hardening, port
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
'  # If web assets missing on Disk, repopulate from baseline in the image\n'\
'  if [ ! -f "$DATA_DIR/web/assets/bootstrap/dist/js/bootstrap.min.js" ]; then\n'\
'    echo "[INFO] Repopulating web assets from baseline...";\n'\
'    mkdir -p "$DATA_DIR/web"; cp -a /opt/chamilo-defaults/web/. "$DATA_DIR/web/" 2>/dev/null || true;\n'\
'  fi;\n'\
'  if [ ! -d "$DATA_DIR/main/default_course_document/images" ] || [ -z "$(ls -A "$DATA_DIR/main/default_course_document/images" 2>/dev/null)" ]; then\n'\
'    mkdir -p "$DATA_DIR/main/default_course_document/images"; cp -a /opt/chamilo-defaults/main/default_course_document/images/. "$DATA_DIR/main/default_course_document/images/" 2>/dev/null || true;\n'\
'  fi;\n'\
'  # Perms on Disk (looser for installer)\n'\
'  chown -R www-data:www-data "$DATA_DIR";\n'\
'  chmod -R 777 "$DATA_DIR"/app "$DATA_DIR"/web "$DATA_DIR"/courses "$DATA_DIR"/archive "$DATA_DIR"/home "$DATA_DIR"/temp "$DATA_DIR"/upload "$DATA_DIR"/main "$DATA_DIR"/app/cache "$DATA_DIR"/app/logs 2>/dev/null || true;\n'\
'  # Add the user-identified fix\n'\
'  if [ -d "/var/www/html/app/courses" ]; then\n'\
'    chmod -R 777 "/var/www/html/app/courses";\n'\
'  fi;\n'\
'\n'\
'  # --- Force critical symlinks to DATA_DIR (docroot side) ---\n'\
'  rm -rf /var/www/html/courses; ln -s "$DATA_DIR/courses" /var/www/html/courses;\n'\
'  rm -rf /var/www/html/web;     ln -s "$DATA_DIR/web"      /var/www/html/web;\n'\
'  mkdir -p "$DATA_DIR/main/default_course_document/images";\n'\
'  rm -rf /var/www/html/main/default_course_document/images; ln -s "$DATA_DIR/main/default_course_document/images" /var/www/html/main/default_course_document/images;\n'\
'\n'\
'  # --- Ensure test course exists BOTH on disk and docroot ---\n'\
'  mkdir -p "$DATA_DIR/courses/__XxTestxX__";\n'\
'  if [ ! -f "$DATA_DIR/courses/__XxTestxX__/test.html" ]; then\n'\
'    echo "<html><body>OK</body></html>" > "$DATA_DIR/courses/__XxTestxX__/test.html";\n'\
'  fi;\n'\
'  chown -R www-data:www-data "$DATA_DIR/courses/__XxTestxX__";\n'\
'  chmod -R 0777 "$DATA_DIR/courses/__XxTestxX__";\n'\
'else\n'\
'  if [ "${ALLOW_EPHEMERAL:-}" = "1" ]; then\n'\
'    echo "[WARN] No persistent disk mounted at $DATA_DIR. Running EPHEMERAL (data will be lost).";\n'\
'    for d in $PERSIST_DIRS; do mkdir -p "/var/www/html/$d"; done;\n'\
'    chown -R www-data:www-data /var/www/html/app /var/www/html/web /var/www/html/main /var/www/html/courses /var/www/html/archive /var/www/html/home /var/www/html/temp /var/www/html/upload;\n'\
'    chmod -R 777 /var/www/html/app /var/www/html/web /var/www/html/main /var/www/html/courses /var/www/html/archive /var/www/html/home /var/www/html/temp /var/www/html/upload;\n'\
'    chmod -R 0777 /var/www/html/web /var/www/html/main/default_course_document/images /var/www/html/courses 2>/dev/null || true;\n'\
'    mkdir -p "/var/www/html/app/courses";\n'\
'    chmod -R 0777 "/var/www/html/app/courses" 2>/dev/null || true;\n'\
'    mkdir -p "/var/www/html/courses/__XxTestxX__";\n'\
'    [ -f "/var/www/html/courses/__XxTestxX__/test.html" ] || echo "<html><body>OK</body></html>" > "/var/www/html/courses/__XxTestxX__/test.html";\n'\
'    chmod -R 0777 "/var/www/html/courses/__XxTestxX__" 2>/dev/null || true;\n'\
'  else\n'\
'    echo "[ERROR] No persistent disk mounted at $DATA_DIR. Attach a Disk or set ALLOW_EPHEMERAL=1." >&2; exit 1;\n'\
'  fi;\n'\
'fi\n'\
'\n'\
'# Make sure app/ is writable during install\n'\
'chown www-data:www-data /var/www/html/app || true\n'\
'chmod 775 /var/www/html/app || true\n'\
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
