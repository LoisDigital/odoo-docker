
FROM ubuntu:jammy

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

ARG ODOO_VERSION
ARG ODOO_REVISION
ARG DEBIAN_FRONTEND=noninteractive

# Generate locale C.UTF-8 for postgres and general locale data
ENV LANG C.UTF-8

# Fix for hash sum mismatch issues - configure apt to be more resilient
RUN echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    echo 'Acquire::Retries 10;' > /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::http::Pipeline-Depth "0";' > /etc/apt/apt.conf.d/99avoid-hashsum-errors && \
    echo 'Acquire::http::No-Cache=True;' >> /etc/apt/apt.conf.d/99avoid-hashsum-errors && \
    echo 'Acquire::BrokenProxy=true;' >> /etc/apt/apt.conf.d/99avoid-hashsum-errors

# Clean apt cache and update before installing packages
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get update

# Install dependencies (from Odoo install documentation)
RUN apt-get update && \
    apt-get install -y --fix-broken --fix-missing libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg-dev libopenjp2-7-dev zlib1g-dev libfreetype6-dev \
    liblcms2-dev libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev libpq-dev \
    python3-pip

# Install additional tools needed for build & run
# For some reason, python3.11 is needed, but Odoo will actually run with Python 3.10.
RUN apt-get update && apt-get install -y python3.11 \ 
    gcc g++ curl git nano postgresql-client

# install wkhtmltox for PDF reports
RUN curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb \
    && echo 967390a759707337b46d1c02452e2bb6b2dc6d59 wkhtmltox.deb | sha1sum -c - \
    && apt-get install -y --no-install-recommends ./wkhtmltox.deb \
    && rm wkhtmltox.deb

# Install Node
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
RUN apt-get install -y nodejs

# Needed for JS tour tests
# RUN pip install websocket-client
# RUN apt-get update
# RUN apt-get install chromium -y
# RUN apt install ffmpeg -y

# Create odoo user and directories and set permissions
RUN useradd -ms /bin/bash odoo \
    && mkdir /etc/odoo /opt/odoo /opt/odoo/scripts \
    && chown -R odoo:odoo /etc/odoo /opt/odoo

# Install Git (for cloning)
RUN apt-get install -y git
WORKDIR /opt/odoo

# Install Odoo and dependencies from source and check out specific revision
USER odoo
RUN git clone --branch=17.0 --depth=1 https://github.com/odoo/odoo.git odoo
# RUN cd odoo && git reset --hard $ODOO_REVISION

# Patch odoo requirements file
# We need to install a different version of gevent.
RUN sed -i "s/gevent==21\.8\.0 ; sys_platform != 'win32' and python_version == '3\.10'/gevent==21\.12\.0 ; sys_platform != 'win32' and python_version == '3\.11'/" odoo/requirements.txt

# Install Odoo python package requirements
USER root
RUN pip3 install pip --upgrade
RUN pip3 install --no-cache-dir -r odoo/requirements.txt

USER odoo

RUN mkdir /opt/odoo/data /opt/odoo/custom_addons \
    /opt/odoo/.vscode /home/odoo/.vscode-server

ENV ODOO_RC /etc/odoo/odoo.conf
ENV PATH="/opt/odoo/scripts:${PATH}"

EXPOSE 8069
ENTRYPOINT ["tail", "-f", "/dev/null"]