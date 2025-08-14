# PHP + Apache
FROM php:8.1-apache

ENV DEBIAN_FRONTEND=noninteractive

# 1) Dependencias de compilación y de runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    zlib1g-dev \
    libicu-dev \
    libxml2-dev \
    unzip \
    git \
    mariadb-client \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 # 2) Extensiones PHP
 && docker-php-ext-install -j"$(nproc)" gd mysqli pdo_mysql zip intl mbstring opcache \
 # 3) Limpiar: quitamos toolchain y cache de apt (manteniendo solo runtime)
 && apt-get purge -y --auto-remove build-essential pkg-config \
 && rm -rf /var/lib/apt/lists/*

# 4) Copiar código (en tu repo está dentro de /chamilo)
COPY chamilo/ /var/www/html/

# 5) Normalizar raíz si el zip dejó una subcarpeta (chamilo/ o chamilo-*)
RUN set -eux; \
 if [ -d /var/www/html/chamilo ] && [ -f /var/www/html/chamilo/index.php ]; then \
   mv /var/www/html/chamilo/* /var/www/html/ && rmdir /var/www/html/chamilo; \
 fi; \
 for d in /var/www/html/chamilo-*; do \
   if [ -d "$d" ] && [ -f "$d/index.php" ]; then \
     mv "$d"/* /var/www/html/ && rmdir "$d"; \
   fi; \
 done

# 6) Apache: mod_rewrite, .htaccess y DirectoryIndex
RUN a2enmod rewrite \
 && printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n" > /etc/apache2/conf-available/override.conf \
 && a2enconf override \
 && printf "DirectoryIndex index.php index.html\n" > /etc/apache2/conf-available/dirindex.conf \
 && a2enconf dirindex

# 7) Permisos y carpetas usadas por Chamilo
RUN chown -R www-data:www-data /var/www/html \
 && find /var/www/html -type d -print0 | xargs -0 chmod 755 \
 && find /var/www/html -type f -print0 | xargs -0 chmod 644 \
 && mkdir -p /var/www/html/app/cache /var/www/html/app/logs || true \
 && chown -R www-data:www-data /var/www/html/app/cache /var/www/html/app/logs || true

# 8) Ajustes PHP recomendados (puedes subirlos si lo necesitas)
RUN { \
  echo "upload_max_filesize=64M"; \
  echo "post_max_size=64M"; \
  echo "memory_limit=512M"; \
  echo "max_execution_time=300"; \
} > /usr/local/etc/php/conf.d/chamilo.ini

# 9) Respetar $PORT de Render en runtime
RUN printf '#!/bin/sh\nset -e\nPORT=${PORT:-80}\n'\
'sed -ri "s/^Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf || true\n'\
'sed -ri "s/:80>/:${PORT}>/" /etc/apache2/sites-available/000-default.conf || true\n'\
'exec apache2-foreground\n' > /usr/local/bin/run-apache.sh \
 && chmod +x /usr/local/bin/run-apache.sh

EXPOSE 80
CMD ["run-apache.sh"]
