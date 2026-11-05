FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
# Do not start daemons while building the image.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update && apt-get install -y --no-install-recommends \
       slurm-wlm slurmdbd mariadb-server munge libswitch-perl \
       make perl bash procps util-linux coreutils gawk grep sed bc hostname debianutils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash sbankci
WORKDIR /opt/slurm-bank
COPY . .
RUN make install PREFIX=/usr/local
ENTRYPOINT ["bash", ".ci/slurm/run.sh"]
