FROM archlinux:latest
LABEL org.opencontainers.image.authors="d1vanloon"
LABEL org.opencontainers.image.source="https://github.com/d1vanloon/minecraftbedrockserver"
LABEL org.opencontainers.image.title="minecraftbedrockserver"
LABEL org.opencontainers.image.description="Arch Linux Minecraft Bedrock Dedicated Server"

# app name from buildx arg
ARG APPNAME=minecraftbedrockserver

# bedrock version or "latest"
ARG RELEASETAG=latest

# arch from buildx --platform, e.g. amd64
ARG TARGETARCH=amd64

# optional explicit download (workflow supplies these; local builds resolve from EndstoneMC)
ARG BEDROCK_URL=
ARG BEDROCK_SHA256=

# gotty release tag
ARG GOTTY_VERSION=v1.8.0

# additional files
##################

ADD build/supervisord.conf /etc/supervisord.conf
ADD build/minecraft-bedrock-server.conf /etc/supervisor/conf.d/minecraft-bedrock-server.conf
ADD build/root/install.sh /root/install.sh
ADD build/root/init.sh /usr/bin/init.sh
ADD build/root/envvars.sh /usr/local/bin/envvars.sh
ADD build/root/waitproc.sh /usr/local/bin/waitproc.sh
ADD build/root/healthcheck.sh /usr/local/bin/healthcheck.sh
ADD run/nobody/*.sh /home/nobody/

ENV PATH="/usr/local/bin:${PATH}"
ENV HOME=/home/nobody
ENV TERM=xterm
ENV LANG=en_US.UTF-8

# install app
#############

RUN chmod +x /root/install.sh /usr/bin/init.sh /usr/local/bin/*.sh /home/nobody/*.sh && \
	/bin/bash /root/install.sh "${APPNAME}" "${RELEASETAG}" "${TARGETARCH}" "${BEDROCK_URL}" "${BEDROCK_SHA256}" "${GOTTY_VERSION}"

# healthcheck
#############

HEALTHCHECK \
	--interval=2m \
	--timeout=2m \
	--retries=3 \
	--start-period=2m \
	CMD /usr/local/bin/healthcheck.sh || exit 1

# run
#####

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/bin/bash", "/usr/bin/init.sh"]
