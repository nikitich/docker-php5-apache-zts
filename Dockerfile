FROM debian:jessie

# prevent Debian's PHP packages from being installed
# https://github.com/docker-library/php/pull/542
RUN set -eux; \
	{ \
		echo 'Package: php*'; \
		echo 'Pin: release *'; \
		echo 'Pin-Priority: -1'; \
	} > /etc/apt/preferences.d/no-debian-php

# persistent / runtime deps
ENV PHPIZE_DEPS \
		autoconf \
		dpkg-dev \
		file \
		g++ \
		gcc \
		libc-dev \
		make \
		pkg-config \
		re2c
RUN echo 'deb http://ftp.debian.org/debian/ jessie non-free' >> /etc/apt/sources.list \
	&& echo 'deb-src http://ftp.debian.org/debian/ jessie non-free' >> /etc/apt/sources.list \
	&& apt-get update && apt-get install -y \
		$PHPIZE_DEPS \
		ca-certificates \
		curl \
		xz-utils \
        ##<custom>##
		libapache2-mod-fastcgi \
		supervisor \
		#libapache2-mod-fcgid \
        mc htop \ 
		gettext \
			##<gd>##
				libfreetype6-dev \
				libjpeg62-turbo-dev \
				libxpm-dev \
				libpng-dev \
			##</gd>##
        ##</custom>##
        ##<pthreads>##
        git \
        unzip \
        ##</pthreads>##
	--no-install-recommends && rm -r /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

##<autogenerated>##
ENV PHP_EXTRA_CONFIGURE_ARGS --enable-maintainer-zts \
	##<custom>##
	--enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
	--enable-bcmath \
	--enable-calendar \
	--with-gettext \
	--enable-sockets \
	--with-mysql \
	--enable-pdo=shared \
	--with-pdo-mysql=shared \
	--with-pdo-sqlite=shared \
		##<gd>##
			--with-gd \
			--with-freetype-dir=/usr/include/ \
			--with-jpeg-dir=/usr/include/ \
			--with-png-dir=/usr/include/ \
			--with-xpm-dir=/usr/include/ \
		##</gd>##
	##</custom>##
			##
    ##<apache2>##
    --with-apxs2
    ##</apache2>##

    ##<apache2>##
        RUN apt-get update \
            && apt-get install -y --no-install-recommends \
                apache2 \
            && rm -rf /var/lib/apt/lists/*

        ENV APACHE_CONFDIR /etc/apache2
        ENV APACHE_ENVVARS $APACHE_CONFDIR/envvars
    ##</apache2>##
##</autogenerated>##

# Apply stack smash protection to functions using local buffers and alloca()
# Make PHP's main executable position-independent (improves ASLR security mechanism, and has no performance impact on x86_64)
# Enable optimization (-O2)
# Enable linker optimization (this sorts the hash buckets to improve cache locality, and is non-default)
# Adds GNU HASH segments to generated executables (this is used if present, and is much faster than sysv hash; in this configuration, sysv hash is also generated)
# https://github.com/docker-library/php/issues/272
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS 0BD78B5F97500D450838F95DFE857D9A90D90EC1 6E4F6AB321FDC07F2C332E3AC2BF0BC433CFC8B3

ENV PHP_VERSION 5.6.33
ENV PHP_URL="https://secure.php.net/get/php-5.6.33.tar.xz/from/this/mirror" PHP_ASC_URL="https://secure.php.net/get/php-5.6.33.tar.xz.asc/from/this/mirror"
ENV PHP_SHA256="9004995fdf55f111cd9020e8b8aff975df3d8d4191776c601a46988c375f3553" PHP_MD5=""

##<apache2>##
    RUN set -ex \
        # generically convert lines like
        #   export APACHE_RUN_USER=www-data
        # into
        #   : ${APACHE_RUN_USER:=www-data}
        #   export APACHE_RUN_USER
        # so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
            && sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS" \
            \
        # setup directories and permissions
        && . "$APACHE_ENVVARS" \
        && for dir in \
            "$APACHE_LOCK_DIR" \
            "$APACHE_RUN_DIR" \
            "$APACHE_LOG_DIR" \
            /var/www/html \
        ; do \
            rm -rvf "$dir" \
            && mkdir -p "$dir" \
            && chown -R "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
        done

    # Apache + PHP requires preforking Apache for best results
    RUN a2dismod mpm_event && a2enmod mpm_prefork actions fastcgi alias proxy_fcgi
	#RUN a2enmod actions fastcgi alias

    # logs should go to stdout / stderr
    RUN set -ex \
        && . "$APACHE_ENVVARS" \
        && ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log" \
        && ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log" \
        && ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"

    # PHP files should be handled by PHP, and should be preferred over any other file type
    RUN { \
            echo '<FilesMatch \.php$>'; \
            #echo '\tSetHandler application/x-httpd-php'; \
			echo 'SetHandler  "proxy:fcgi://localhost:9000"'; \
            echo '</FilesMatch>'; \
            echo; \
            echo 'DirectoryIndex disabled'; \
            echo 'DirectoryIndex index.php index.html'; \
            echo; \
            echo '<Directory /var/www/>'; \
            echo '\tOptions -Indexes'; \
            echo '\tAllowOverride All'; \
            echo '</Directory>'; \
        } | tee "$APACHE_CONFDIR/conf-available/docker-php.conf" \
        && a2enconf docker-php

ENV PHP_EXTRA_BUILD_DEPS apache2-dev
##</apache2>##


RUN set -xe; \
	\
	fetchDeps=' \
		wget \
	'; \
	if ! command -v gpg > /dev/null; then \
		fetchDeps="$fetchDeps \
			dirmngr \
			gnupg \
		"; \
	fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends $fetchDeps; \
	rm -rf /var/lib/apt/lists/*; \
	\
	mkdir -p /usr/src; \
	cd /usr/src; \
	\
	wget -O php.tar.xz "$PHP_URL"; \
	\
	if [ -n "$PHP_SHA256" ]; then \
		echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
	fi; \
	if [ -n "$PHP_MD5" ]; then \
		echo "$PHP_MD5 *php.tar.xz" | md5sum -c -; \
	fi; \
	\
	if [ -n "$PHP_ASC_URL" ]; then \
		wget -O php.tar.xz.asc "$PHP_ASC_URL"; \
		export GNUPGHOME="$(mktemp -d)"; \
		for key in $GPG_KEYS; do \
			gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
		done; \
		gpg --batch --verify php.tar.xz.asc php.tar.xz; \
		rm -rf "$GNUPGHOME"; \
	fi; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $fetchDeps

COPY docker-php-source /usr/local/bin/

RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libcurl4-openssl-dev \
		libedit-dev \
		libsqlite3-dev \
		libssl-dev \
		libxml2-dev \
		zlib1g-dev \
		${PHP_EXTRA_BUILD_DEPS:-} \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	export \
		CFLAGS="$PHP_CFLAGS" \
		CPPFLAGS="$PHP_CPPFLAGS" \
		LDFLAGS="$PHP_LDFLAGS" \
	; \
	docker-php-source extract; \
	cd /usr/src/php; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
# https://bugs.php.net/bug.php?id=74125
	if [ ! -d /usr/include/curl ]; then \
		ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
	fi; \
	./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		\
		--disable-cgi \
		\
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
		--enable-ftp \
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
		--enable-mbstring \
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
		--enable-mysqlnd \
		\
		--with-curl \
		--with-libedit \
		--with-openssl \
		--with-zlib \
		\
# bundled pcre does not support JIT on s390x
# https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		--with-libdir="lib/$debMultiarch" \
		\
		${PHP_EXTRA_CONFIGURE_ARGS:-} \
	; \
	make -j "$(nproc)"; \
	make install; \
	find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; \
	make clean; \
	cd /; \
	docker-php-source delete; \
	\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
	find /usr/local -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { print $(NF-1) }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	\
	php --version; \
	\
# https://github.com/docker-library/php/issues/443
	pecl update-channels; \
	rm -rf /tmp/pear ~/.pearrc

COPY docker-php-ext-* docker-php-entrypoint /usr/local/bin/

##<pthreads>##
RUN cd /usr/src/ \
&& curl -fSL "https://github.com/krakjoe/pthreads/archive/PHP5.zip" -o pthreads.zip \
&& unzip pthreads.zip \
&& cd pthreads-PHP5/ \
&& pear install package.xml \
&& docker-php-ext-enable pthreads \
&& rm -rf /user/src/pthreads-PHP5/*
##</pthreads>##

##<custom>##
RUN apt-get update && apt-get install -y \
		libmcrypt-dev \
	&& docker-php-ext-install -j$(nproc) \
		mcrypt
##</custom>##

ENTRYPOINT ["docker-php-entrypoint"]
##<autogenerated>##
COPY apache2-foreground /usr/local/bin/
WORKDIR /var/www/html

RUN set -ex \
	&& cd /usr/local/etc \
	&& if [ -d php-fpm.d ]; then \
		# for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
		sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
		cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
	else \
		# PHP 5.x doesn't use "include=" by default, so we'll create our own simple config that mimics PHP 7+ for consistency
		mkdir php-fpm.d; \
		cp php-fpm.conf.default php-fpm.d/www.conf; \
		{ \
			echo '[global]'; \
			echo 'include=etc/php-fpm.d/*.conf'; \
		} | tee php-fpm.conf; \
	fi \
	&& { \
		echo '[global]'; \
		echo 'error_log = /proc/self/fd/2'; \
		echo; \
		echo '[www]'; \
		echo '; if we send this to /proc/self/fd/1, it never appears'; \
		echo 'access.log = /proc/self/fd/2'; \
		echo; \
		echo 'clear_env = no'; \
		echo; \
		echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
		echo 'catch_workers_output = yes'; \
	} | tee php-fpm.d/docker.conf \
	&& { \
		echo '[global]'; \
		echo 'daemonize = no'; \
		echo; \
		echo '[www]'; \
		echo 'listen = 9000'; \
} | tee php-fpm.d/zz-docker.conf

EXPOSE 80
EXPOSE 9000

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
#CMD ["/usr/bin/supervisord"]
CMD ["apache2-foreground"]

##</autogenerated>##