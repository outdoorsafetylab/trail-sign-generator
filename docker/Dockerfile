# syntax=docker/dockerfile:1
FROM ubuntu:24.10

RUN sed -i 's/archive.ubuntu.com/free.nchc.org.tw/g' /etc/apt/sources.list
RUN apt-get update && apt-get install -y locales \
	&& localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.utf8
ENV TZ=Asia/Taipei
RUN echo $TZ > /etc/timezone && apt-get update && apt-get install -y --no-install-recommends tzdata
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && dpkg-reconfigure -f noninteractive tzdata
RUN echo "dash dash/sh boolean false" | debconf-set-selections; dpkg-reconfigure -f noninteractive dash

RUN apt-get install -y python3 python3-pip

RUN apt-get install -y \
    ghostscript \
    inkscape \
    poppler-utils \
    ruby

RUN rm -rf /var/lib/apt/lists/*

USER root
ADD ./rootfs /
RUN fc-cache -f -v
RUN fc-list | grep "Noto Sans"
RUN echo '%sudo ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN addgroup builder
RUN useradd -m -d /home/builder -s /bin/bash -g builder -G adm,dialout,sudo,dip,plugdev builder

USER builder
RUN mkdir /home/builder/workdir
WORKDIR /home/builder/workdir

ENTRYPOINT ["ruby", "generate.rb"]
CMD []
