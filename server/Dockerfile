FROM alpine:3.16.3
# todo: freeze dependency versions
#   I think the only thing left is luarocks packages, but apparently the luarocks
#   in alpine (2.x) doesn't yet have --pin (3.x)?? wth
RUN set -euo pipefail; \
	IFS=$'\t\n'; \
	APK_INSTALLED_PERMANENTLY=$'dumb-init\tpcre\topenssl3\tzlib\tlua5.1\tluajit'; \
	APK_INSTALLED_TEMPORARILY=$'gcc\twget\tperl\tmake\tpcre-dev\topenssl3-dev\tzlib-dev\tmusl-dev\tsudo\tlua5.1-dev\tluajit-dev\tluarocks5.1'; \
	LUAROCKS_INSTALLED_PERMANENTLY=$'lapis\tbasexx\tlunajson'; \
	apk add --no-cache $APK_INSTALLED_PERMANENTLY; \
	apk add --no-cache $APK_INSTALLED_TEMPORARILY; \
	for i in $LUAROCKS_INSTALLED_PERMANENTLY; do \
		sudo -H luarocks-5.1 install $i; \
	done; \
	openresty=openresty-1.21.4.1; \
		wget https://openresty.org/download/$openresty.tar.gz; \
		tar xf $openresty.tar.gz; \
		(cd $openresty; \
			./configure --with-luajit=/usr; \
			make -j$(nproc); \
			make install); \
		rm -rf $openresty $openresty.tar.gz; \
	apk del --no-cache $APK_INSTALLED_TEMPORARILY
WORKDIR /tpt-scripts
RUN adduser --disabled-password --no-create-home tpt-scripts
RUN for i in logs temp data; do \
		mkdir -p $i && chmod 777 $i && chown tpt-scripts:tpt-scripts $i; \
	done
RUN touch nginx.conf.compiled
RUN chown tpt-scripts:tpt-scripts nginx.conf.compiled
USER tpt-scripts:tpt-scripts
VOLUME /tpt-scripts/logs
VOLUME /tpt-scripts/temp
VOLUME /tpt-scripts/data
EXPOSE 3001
ADD . .
ENTRYPOINT ["dumb-init", "lapis", "server"]
