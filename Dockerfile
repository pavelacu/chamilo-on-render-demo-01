# =========================
# Etapa 1: deps (PHP 7.4 CLI + Composer)
# =========================
FROM php:7.4-cli AS deps

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends git unzip curl libzip-dev zlib1g-dev; \
  docker-php-ext-install -j"$(nproc)" zip; \
  rm -rf /var/lib/apt/lists/*

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
  --install-dir=/usr/local/bin --filename=composer

# Copia Chamilo desde tu repo
COPY chamilo/ /app/

# Instala dependencias (runtime tendrá las extensiones)
RUN set -eux; \
  composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader \
    --ignore-platform-req=ext-gd \
    --ignore-platform-req=ext-intl \
    --ignore-platform-req=ext-soap; \
  test -f /app/vendor/autoload.php

# =========================
# Etapa 2: runtime (Apache + PHP 7.4)
# =========================
FROM php:7.4-apache

ENV DEBIAN_FRONTEND=noninteractive

# Paquetes/extensiones PHP necesarias
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

# (Opcional) limpiar toolchain
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# Copia código + vendor generado
COPY --from=deps /app/ /var/www/html/

# Apache: rewrite, headers (HTTPS), AllowOverride, DirectoryIndex
RUN set -eux; \
  a2enmod rewrite headers; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\nServerName localhost\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex; \
  printf "SetEnvIf X-Forwarded-Proto \"^https$\" HTTPS=on\n" > /etc/apache2/conf-available/forwarded.conf; \
  a2enconf forwarded

# Script de arranque:
# - migra/engancha dirs de escritura a un Disk montado en /var/www/chamilo-data
# - endurece tras instalación (solo si ya existe configuration.php)
RUN printf '#!/bin/sh\nset -e\n'\
'PORT=${PORT:-80}\n'\
'DATA_DIR=${CHAMILO_DATA:-/var/www/chamilo-data}\n'\
'# Asegurar directorio de datos (Disk) y enlazar carpetas de escritura\n'\
'for d in app/config app/cache app/logs courses archive home temp upload; do\n'\
'  SRC="/var/www/html/$d"\n'\
'  DST="$DATA_DIR/$d"\n'\
'  mkdir -p "$DATA_DIR" "$DST"\n'\
'  if [ ! -L "$SRC" ]; then\n'\
'    if [ -d "$SRC" ]; then\n'\
'      shopt -s dotglob nullglob 2>/dev/null || true\n'\
'      mv "$SRC"/* "$DST"/ 2>/dev/null || true\n'\
'      rmdir "$SRC" 2>/dev/null || true\n'\
'    fi\n'\
'    ln -s "$DST" "$SRC"\n'\
'  fi\n'\
'done\n'\
'# Permisos (www-data) en el Disk\n'\
'chown -R www-data:www-data "$DATA_DIR"\n'\
'chmod -R 775 "$DATA_DIR"/{courses,archive,home,temp,upload,app/cache,app/logs} 2>/dev/null || true\n'\
'# Endurecimiento post-instalación\n'\
'if [ -f "$DATA_DIR/app/config/configuration.php" ]; then\n'\
'  chmod -R 0555 "$DATA_DIR/app/config" || true\n'\
'  rm -rf /var/www/html/main/install || true\n'\
'fi\n'\
'# Ajustar Apache al puerto de Render\n'\
'sed -ri "s/^Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf || true\n'\
'sed -ri "s/:80>/:${PORT}>/" /etc/apache2/sites-available/000-default.conf || true\n'\
'exec apache2-foreground\n' > /usr/local/bin/run-apache.sh \
 && chmod +x /usr/local/bin/run-apache.sh

EXPOSE 80
CMD ["run-apache.sh"]
