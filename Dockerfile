FROM php:8.1-apache

ENV DEBIAN_FRONTEND=noninteractive

# 1) Dependencias de compilación y runtime
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    build-essential \
    autoconf \
    pkg-config \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    zlib1g-dev \
    libicu-dev \
    libxml2-dev \
    libonig-dev \
    unzip \
    git \
    default-mysql-client; \
  rm -rf /var/lib/apt/lists/*

# 2) Extensiones PHP (separadas para aislar errores)
# gd con JPEG/Freetype
RUN set -eux; \
  docker-php-ext-configure gd --with-freetype --with-jpeg; \
  docker-php-ext-install -j"$(nproc)" gd

# mysqli + pdo_mysql
RUN set -eux; \
  docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql

# zip
RUN set -eux; \
  docker-php-ext-install -j"$(nproc)" zip

# intl
RUN set -eux; \
  docker-php-ext-install -j"$(nproc)" intl

# mbstring y opcache
RUN set -eux; \
  docker-php-ext-install -j"$(nproc)" mbstring opcache

# 3) (Opcional) limpiar toolchain para aligerar imagen
RUN set -eux; \
  apt-get update; \
  apt-get purge -y --auto-remove build-essential autoconf pkg-config; \
  rm -rf /var/lib/apt/lists/*

# 4) Copiar Chamilo (en tu repo está bajo /chamilo)
COPY chamilo/ /var/www/html/

# 5) Normalizar si el zip dejó subcarpeta (chamilo/ o chamilo-*)
RUN set -eux; \
  if [ -d /var/www/html/chamilo ] && [ -f /var/www/html/chamilo/index.php ]; then \
    mv /var/www/html/chamilo/* /var/www/html/ && rmdir /var/www/html/chamilo; \
  fi; \
  for d in /var/www/html/chamilo-*; do \
    if [ -d "$d" ] && [ -f "$d/index.php" ]; then \
      mv "$d"/* /var/www/html/ && rmdir "$d"; \
    fi; \
  done

# 6) Apache: rewrite, AllowOverride y DirectoryIndex
RUN set -eux; \
  a2enmod rewrite; \
  printf "<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n" > /etc/apache2/conf-available/override.conf; \
  a2enconf override; \
  printf "DirectoryIndex index.php index.html\n" > /etc/apache2/conf-available/dirindex.conf; \
  a2enconf dirindex

# 7) Permisos y carpetas cache/logs de Chamilo (sin xargs)
RUN set -eux; \
  chown -R www-data:www-data /var/www/html; \
  find /var/www/html -type d -exec chmod 755 {} +; \
  find /var/www/html -type f -exec chmod 644 {} +; \
  install -d -o www-data -g www-data /var/www/html/app/cache /var/www/html/app/logs

# 8) Ajustes PHP recomendados
RUN set -eux; { \
  echo "upload_max_filesize=64M"; \
  echo "post_max_size=64M"; \
  echo "memory_limit=512M"; \
  echo "max_execution_time=300"; \
} > /usr/local/etc/php/conf.d/chamilo.ini

# 9) Respetar $PORT de Render
RUN printf '#!/bin/sh\nset -e\nPORT=${PORT:-80}\n'\
'sed -ri "s/^Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf || true\n'\
'sed -ri "s/:80>/:${PORT}>/" /etc/apache2/sites-available/000-default.conf || true\n'\
'exec apache2-foreground\n' > /usr/local/bin/run-apache.sh \
 && chmod +x /usr/local/bin/run-apache.sh

EXPOSE 80
CMD ["run-apache.sh"]
