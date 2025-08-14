# Imagen base con PHP y Apache
FROM php:8.1-apache

# Instalar extensiones requeridas por Chamilo
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    unzip \
    git \
    mariadb-client \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd mysqli pdo pdo_mysql zip intl

# Copiar el código de Chamilo al directorio de Apache
COPY . /var/www/html/

# Dar permisos
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

# Habilitar mod_rewrite
RUN a2enmod rewrite
