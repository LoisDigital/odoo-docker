
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
    gcc g++ curl git nano postgresql-client sudo

# install wkhtmltox for PDF reports
RUN curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb \
    && echo 967390a759707337b46d1c02452e2bb6b2dc6d59 wkhtmltox.deb | sha1sum -c - \
    && apt-get install -y --no-install-recommends ./wkhtmltox.deb \
    && rm wkhtmltox.deb

# Install Node
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
RUN apt-get install -y nodejs

# Forest Panda repairs generated audio with pydub, which requires ffmpeg.
# Keep this late in the image so adding or updating it does not invalidate the
# expensive Odoo source and Python-dependency layers above.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Needed for JS tour tests
# RUN pip install websocket-client
# RUN apt-get update
# RUN apt-get install chromium -y

# Create odoo user and directories and set permissions
RUN useradd -ms /bin/bash odoo \
    && mkdir /etc/odoo /opt/odoo /opt/odoo/scripts \
    && chown -R odoo:odoo /etc/odoo /opt/odoo \
    && echo "odoo ALL=(ALL) NOPASSWD: /usr/bin/pip3" >> /etc/sudoers

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

# Create the custom requirements installation script
RUN echo '#!/bin/bash' > /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '# Script to install requirements from custom Odoo modules' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '# This script finds all custom modules (identified by __manifest__.py)' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '# and installs their requirements.txt if present' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo 'echo "Checking for custom module requirements..."' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '# Find all directories with __manifest__.py files in custom_addons' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo 'find /opt/odoo/custom_addons -name "__manifest__.py" -exec dirname {} \; | while read module_dir; do' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '    if [ -f "$module_dir/requirements.txt" ]; then' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '        echo "Installing requirements for module: $module_dir"' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '        sudo pip3 install --no-cache-dir -r "$module_dir/requirements.txt"' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '        if [ $? -eq 0 ]; then' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '            echo "Successfully installed requirements for $module_dir"' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '        else' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '            echo "Failed to install requirements for $module_dir"' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '        fi' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '    fi' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo 'done' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo '' >> /opt/odoo/scripts/install_custom_requirements.sh && \
    echo 'echo "Custom requirements installation complete."' >> /opt/odoo/scripts/install_custom_requirements.sh

RUN chmod +x /opt/odoo/scripts/install_custom_requirements.sh

# Create an entrypoint script that installs requirements and then runs the command
RUN echo '#!/bin/bash' > /opt/odoo/scripts/entrypoint.sh && \
    echo '' >> /opt/odoo/scripts/entrypoint.sh && \
    echo '# Install custom requirements first' >> /opt/odoo/scripts/entrypoint.sh && \
    echo '/opt/odoo/scripts/install_custom_requirements.sh' >> /opt/odoo/scripts/entrypoint.sh && \
    echo '' >> /opt/odoo/scripts/entrypoint.sh && \
    echo '# Execute the command passed to the container' >> /opt/odoo/scripts/entrypoint.sh && \
    echo 'exec "$@"' >> /opt/odoo/scripts/entrypoint.sh

RUN chmod +x /opt/odoo/scripts/entrypoint.sh

RUN mkdir /opt/odoo/data /opt/odoo/custom_addons \
    /opt/odoo/.vscode /home/odoo/.vscode-server

ENV ODOO_RC /etc/odoo/odoo.conf
ENV PATH="/opt/odoo/scripts:${PATH}"

EXPOSE 8069
ENTRYPOINT ["/opt/odoo/scripts/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
