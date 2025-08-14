# =========================
# Etapa 1: deps (PHP 7.4 CLI + Composer)
# =========================
FROM php:7.4-cli AS deps

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# Herramientas y ZIP para Composer
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends git unzip curl libzip-dev zlib1g-dev; \
  docker-php-ext-install -j"$(nproc)" zip; \
  rm -rf /var/lib/apt/lists/*

# Instalar Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
  --install-dir=/usr/local/bin \
  --filename=composer

# Copiar Chamilo desde tu repo (carpeta 'chamilo/')
COPY chamilo/ /app/

# Instalar dependencias PHP (ignora reqs de extensiones en CLI; en runtime sí estarán)
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

# Paquetes para compilar/extensiones requeridas por Chamilo
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    build-essential autoconf pkg-config \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev zlib1g-dev \
    libicu-dev libxml2-dev libonig-dev \
    default-mysql-client; \
  rm -rf /var/lib/apt/lists/*

# Extensiones PHP (gd, mysqli, pdo_mysql, zip, intl, mbstring, opcache, soap)
RUN set -eux; \
  docker-php-ext-configure gd --with-freetype --with-jpeg; \
  docker-php-ext-install -j"$(nproc)" gd mysqli pdo_mysql zip intl mbstring opcache soap

# (Opcional) Limpieza de toolchain para aligerar
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# Copiar código + vendor desde la etapa deps
COPY --from=deps /app/ /var/www/html/

# Apache: mod_rewrite, AllowOverride, DirectoryIndex, ServerName
RUN set -eux; \
  a2enmod rewrite; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\nServerName localhost\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex

# Permisos y carpetas necesarias
RUN set -eux; \
  chown -R www-data:www-data /var/www/html; \
  find /var/www/html -type d -exec chmod 755 {} +; \
  find /var/www/html -type f -exec chmod 644 {} +; \
  install -d -o www-data -g www-data /var/www/html/app/cache /var/www/html/app/logs

# Ajustes PHP
RUN set -eux; { \
  echo "upload_max_filesize=64M"; \
  echo "post_max_size=64M"; \
  echo "memory_limit=512M"; \
  echo "max_execution_time=300"; \
} > /usr/local/etc/php/conf.d/chamilo.ini

# Respetar $PORT de Render
RUN printf '#!/bin/sh\nset -e\nPORT=${PORT:-80}\n'\
'sed -ri "s/^Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf || true\n'\
'sed -ri "s/:80>/:${PORT}>/" /etc/apache2/sites-available/000-default.conf || true\n'\
'exec apache2-foreground\n' > /usr/local/bin/run-apache.sh \
 && chmod +x /usr/local/bin/run-apache.sh

EXPOSE 80
CMD ["run-apache.sh"]
