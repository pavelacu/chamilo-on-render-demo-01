# PHP + Apache (Debian) estable
FROM php:8.1-apache

# Evita prompts de apt
ENV DEBIAN_FRONTEND=noninteractive

# Paquetes necesarios para las extensiones de PHP que pide Chamilo
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    zlib1g-dev \
    libicu-dev \
    libxml2-dev \
    unzip \
    git \
    mariadb-client \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j$(nproc) gd mysqli pdo_mysql zip intl \
 # Opcional pero recomendado: OPcache
 && docker-php-ext-install -j$(nproc) opcache \
 # Limpiar cache de apt para reducir la imagen
 && rm -rf /var/lib/apt/lists/*

# Copia el código (ajusta si tu código está en otra carpeta)
COPY chamilo/ /var/www/html/

# Apache: habilitar mod_rewrite y permitir .htaccess
RUN a2enmod rewrite \
 && printf "<Directory /var/www/html>\n\
    AllowOverride All\n\
    Require all granted\n\
</Directory>\n" > /etc/apache2/conf-available/override.conf \
 && a2enconf override

# Permisos
RUN chown -R www-data:www-data /var/www/html \
 && find /var/www/html -type d -exec chmod 755 {} \; \
 && find /var/www/html -type f -exec chmod 644 {} \;

# (Opcional) Ajustes PHP recomendados para instalador de Chamilo
RUN { \
    echo "upload_max_filesize=64M"; \
    echo "post_max_size=64M"; \
    echo "memory_limit=512M"; \
    echo "max_execution_time=300"; \
} > /usr/local/etc/php/conf.d/chamilo.ini

# Puerto por defecto en Render
EXPOSE 80
