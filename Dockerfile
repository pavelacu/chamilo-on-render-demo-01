# ---------- Etapa 1: construir dependencias PHP con Composer ----------
FROM composer:2 AS deps
WORKDIR /app
ENV COMPOSER_ALLOW_SUPERUSER=1

# Copiamos TODO Chamilo del repo (está en /chamilo) a la etapa de build
COPY chamilo/ /app/

# Instala dependencias de PHP (sin dev) y optimiza el autoloader
RUN composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader

# Verificación temprana: debe existir vendor/autoload.php o fallar el build
RUN test -f /app/vendor/autoload.php

# ---------- Etapa 2: runtime con Apache + PHP ----------
FROM php:8.1-apache

ENV DEBIAN_FRONTEND=noninteractive

# Paquetes de runtime y toolchain para compilar extensiones
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    build-essential autoconf pkg-config \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev zlib1g-dev \
    libicu-dev libxml2-dev libonig-dev \
    default-mysql-client curl unzip git; \
  rm -rf /var/lib/apt/lists/*

# Extensiones PHP requeridas por Chamilo
RUN set -eux; \
  docker-php-ext-configure gd --with-freetype --with-jpeg; \
  docker-php-ext-install -j"$(nproc)" gd mysqli pdo_mysql zip intl mbstring opcache

# (Opcional) limpiar toolchain para aligerar imagen
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# Copiamos el resultado de la Etapa 1 (código + vendor) al DocumentRoot
COPY --from=deps /app/ /var/www/html/

# Apache: rewrite, AllowOverride, DirectoryIndex y ServerName
RUN set -eux; \
  a2enmod rewrite; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\nServerName localhost\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex

# Permisos y carpetas de cache/logs
RUN set -eux; \
  chown -R www-data:www-data /var/www/html; \
  find /var/www/html -type d -exec chmod 755 {} +; \
  find /var/www/html -type f -exec chmod 644 {} +; \
  install -d -o www-data -g www-data /var/www/html/app/cache /var/www/html/app/logs

# Ajustes PHP recomendados
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
