FROM alpine:3.24 AS build

RUN apk update \
	&& apk add --no-cache alpine-sdk sudo bash python3

RUN adduser -D builder \
	&& addgroup builder abuild \
	&& echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder
RUN abuild-keygen -a -i -n

ENV APORTSDIR=/home/builder/aports \
	REPODEST=/home/builder/packages \
	OUTDIR=/out

RUN mkdir -p /home/builder/aports /home/builder/packages \
	&& sudo mkdir -p /out \
	&& sudo chown builder:builder /out

USER root
COPY scripts/docker-abuild.sh /usr/local/bin/docker-abuild.sh
RUN chmod 755 /usr/local/bin/docker-abuild.sh

COPY --chown=builder:builder main /home/builder/aports/main

ARG PACKAGE
ENV PACKAGE=${PACKAGE}

USER builder
RUN /usr/local/bin/docker-abuild.sh

FROM scratch AS artifact
COPY --from=build /out/ /
