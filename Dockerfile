# syntax=docker/dockerfile:1
# https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/reference.md

# Stage: compile-frontend
# Purpose: Compiles the frontend
# Notes:
#  - Does NPM stuff with Typescript and such
FROM --platform=$BUILDPLATFORM docker.io/node:20-bookworm-slim AS compile-frontend

COPY ./src-ui /src/src-ui

WORKDIR /src/src-ui
RUN set -eux \
  && npm update npm -g \
  && npm ci --omit=optional
RUN set -eux \
  && ./node_modules/.bin/ng build --configuration production


# Stage: python-base
# Purpose: Single base stage to change Python version and set Python related
#          environment
FROM docker.io/python:3.11-slim-bookworm as python-base

# https://docs.python.org/3/using/cmdline.html#envvar-PYTHONDONTWRITEBYTECODE
ENV PYTHONDONTWRITEBYTECODE=1

# Stage: pipenv-base
# Purpose: Generates a requirements.txt file for building
# Comments:
#  - pipenv dependencies are not left in the final image
#  - pipenv can't touch the final image somehow
#  - build platform only instead of doing it twice
FROM --platform=$BUILDPLATFORM python-base as pipenv-base

WORKDIR /usr/src/pipenv

COPY Pipfile* ./

RUN set -eux \
  && echo "Installing pipenv" \
    && python3 -m pip install --no-cache-dir --upgrade pipenv==2023.9.8 \
  && echo "Generating requirement.txt" \
    && pipenv requirements > requirements.txt

# Stage: static-compression
# Purpose: Compresses the static files ahead of time, using whitenoise
# Comments:
#  - Uses the same cache ID to help with speeding up the second install below
#  - Minimal set of Python packages installed here to run collectstatic
#  - Versions shouldn't matter here
FROM --platform=$BUILDPLATFORM python-base as static-compression

WORKDIR /usr/src/paperless/src/

# copy backend
COPY ./src /usr/src/paperless/src/

# copy frontend
COPY --from=compile-frontend /src/src/documents/static/frontend/ /usr/src/paperless/src/documents/static/frontend/

# hadolint ignore=DL3042
RUN --mount=type=cache,target=/root/.cache/pip/,id=pip-cache \
  set -eux \
  && echo "Installing basic dependencies" \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
      curl \
      patch \
      libmagic1 \
  && echo "Installing minimal Python dependencies" \
    && python3 -m pip install --default-timeout=1000 \
      django \
      whitenoise \
      brotli \
      zstandard \
      celery \
      concurrent-log-handler \
      python-dotenv \
      django-cors-headers \
      django-extensions \
      djangorestframework \
      python-ipware \
      django-filter \
      django-celery-results \
      django-guardian \
      django-extensions \
      pathvalidate \
      django-multiselectfield \
      python-magic \
      filelock \
  && echo "Patching whitenoise for compression speedup" \
    && curl --fail --silent --show-error --location --output 484.patch https://github.com/evansd/whitenoise/pull/484.patch \
    && patch -d /usr/local/lib/python3.11/site-packages --verbose -p2 < 484.patch \
  && echo "Collecting and compressing static files" \
      && python3 manage.py collectstatic --clear --no-input --link \
  && echo "Cleaning up image" \
    && apt-get --yes autoremove --purge \
    && apt-get clean --yes \
    && rm --recursive --force --verbose /var/lib/apt/lists/* \
    && rm --recursive --force --verbose /tmp/* \
    && rm --recursive --force --verbose /var/tmp/* \
    && rm --recursive --force --verbose /var/cache/apt/archives/* \
    && truncate --size 0 /var/log/*log

# Stage: main-app
# Purpose: The final image
# Comments:
#  - Don't leave anything extra in here
FROM python-base as main-app

LABEL org.opencontainers.image.authors="paperless-ngx team <hello@paperless-ngx.com>"
LABEL org.opencontainers.image.documentation="https://docs.paperless-ngx.com/"
LABEL org.opencontainers.image.source="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.url="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive

# Buildx provided, must be defined to use though
ARG TARGETARCH

# Can be workflow provided, defaults set for manual building
ARG JBIG2ENC_VERSION=0.29
ARG QPDF_VERSION=11.6.1
ARG GS_VERSION=10.02.0

#
# Begin installation and configuration
# Order the steps below from least often changed to most
#

# Packages need for running
ARG RUNTIME_PACKAGES="\
  # General utils
  curl \
  # Docker specific
  gosu \
  # Timezones support
  tzdata \
  # fonts for text file thumbnail generation
  fonts-liberation \
  gettext \
  ghostscript \
  gnupg \
  icc-profiles-free \
  imagemagick \
  # PostgreSQL
  libpq5 \
  postgresql-client \
  # MySQL / MariaDB
  mariadb-client \
  # OCRmyPDF dependencies
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-deu \
  tesseract-ocr-fra \
  tesseract-ocr-ita \
  tesseract-ocr-spa \
  unpaper \
  pngquant \
  jbig2dec \
  # lxml
  libxml2 \
  libxslt1.1 \
  # itself
  qpdf \
  # Mime type detection
  file \
  libmagic1 \
  media-types \
  zlib1g \
  # Barcode splitter
  libzbar0 \
  poppler-utils"

# Install basic runtime packages.
# These change very infrequently
RUN set -eux \
  echo "Installing system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${RUNTIME_PACKAGES} \
    && echo "Installing pre-built updates" \
      && echo "Installing qpdf ${QPDF_VERSION}" \
        && curl --fail --silent --show-error --output libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb \
      && echo "Installing Ghostscript ${GS_VERSION}" \
        && curl --fail --silent --show-error --output libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output libgs10-common_${GS_VERSION}.dfsg-2_all.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libgs10-common_${GS_VERSION}.dfsg-2_all.deb \
        && dpkg --install ./libgs10-common_${GS_VERSION}.dfsg-2_all.deb \
        && dpkg --install ./libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && dpkg --install ./ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
      && echo "Installing jbig2enc" \
        && curl --fail --silent --show-error --output jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb \
      && echo "Cleaning up image layer" \
        && rm --force --verbose *.deb \
    && rm --recursive --force --verbose /var/lib/apt/lists/* \
  && echo "Installing supervisor" \
    && python3 -m pip install --default-timeout=1000 --upgrade --no-cache-dir supervisor==4.2.5

# Copy gunicorn config
# Changes very infrequently
WORKDIR /usr/src/paperless/

COPY gunicorn.conf.py /usr/src/paperless/gunicorn.conf.py

# setup docker-specific things
# These change sometimes, but rarely
WORKDIR /usr/src/paperless/src/docker/

COPY [ \
  "docker/imagemagick-policy.xml", \
  "docker/supervisord.conf", \
  "docker/docker-entrypoint.sh", \
  "docker/docker-prepare.sh", \
  "docker/paperless_cmd.sh", \
  "docker/wait-for-redis.py", \
  "docker/env-from-file.sh", \
  "docker/management_script.sh", \
  "docker/flower-conditional.sh", \
  "docker/install_management_commands.sh", \
  "/usr/src/paperless/src/docker/" \
]

RUN set -eux \
  && echo "Configuring ImageMagick" \
    && mv imagemagick-policy.xml /etc/ImageMagick-6/policy.xml \
  && echo "Configuring supervisord" \
    && mkdir /var/log/supervisord /var/run/supervisord \
    && mv supervisord.conf /etc/supervisord.conf \
  && echo "Setting up Docker scripts" \
    && mv docker-entrypoint.sh /sbin/docker-entrypoint.sh \
    && chmod 755 /sbin/docker-entrypoint.sh \
    && mv docker-prepare.sh /sbin/docker-prepare.sh \
    && chmod 755 /sbin/docker-prepare.sh \
    && mv wait-for-redis.py /sbin/wait-for-redis.py \
    && chmod 755 /sbin/wait-for-redis.py \
    && mv env-from-file.sh /sbin/env-from-file.sh \
    && chmod 755 /sbin/env-from-file.sh \
    && mv paperless_cmd.sh /usr/local/bin/paperless_cmd.sh \
    && chmod 755 /usr/local/bin/paperless_cmd.sh \
    && mv flower-conditional.sh /usr/local/bin/flower-conditional.sh \
    && chmod 755 /usr/local/bin/flower-conditional.sh \
  && echo "Installing managment commands" \
    && chmod +x install_management_commands.sh \
    && ./install_management_commands.sh

WORKDIR /usr/src/paperless/src/

# Python dependencies
# Change pretty frequently
COPY --from=pipenv-base /usr/src/pipenv/requirements.txt /usr/src/paperless/src/requirements.txt

# Packages needed only for building a few quick Python
# dependencies
ARG BUILD_PACKAGES="\
  build-essential \
  git \
  # https://www.psycopg.org/docs/install.html#prerequisites
  libpq-dev \
  # https://github.com/PyMySQL/mysqlclient#linux
  default-libmysqlclient-dev \
  pkg-config"

# hadolint ignore=DL3042
RUN --mount=type=cache,target=/root/.cache/pip/,id=pip-cache \
  set -eux \
  && echo "Installing build system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${BUILD_PACKAGES} \
    && python3 -m pip install --no-cache-dir --upgrade wheel \
  && echo "Installing Python requirements" \
    && python3 -m pip install --default-timeout=1000 --requirement requirements.txt \
  && echo "Installing NLTK data" \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" snowball_data \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" stopwords \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" punkt \
  && echo "Cleaning up image" \
    && apt-get --yes purge ${BUILD_PACKAGES} \
    && apt-get --yes autoremove --purge \
    && apt-get clean --yes \
    && rm --recursive --force --verbose /var/lib/apt/lists/* \
    && rm --recursive --force --verbose /tmp/* \
    && rm --recursive --force --verbose /var/tmp/* \
    && rm --recursive --force --verbose /var/cache/apt/archives/* \
    && truncate --size 0 /var/log/*log

# copy compressed static files
COPY --from=static-compression /usr/src/paperless/ /usr/src/paperless/

# add users, create folders and adjust permissions
RUN set -eux \
  && echo "Setting up user/group" \
    && addgroup --gid 1000 paperless \
    && useradd --uid 1000 --gid paperless --home-dir /usr/src/paperless paperless \
  && echo "Creating volume directories" \
    && mkdir --parents --verbose /usr/src/paperless/data \
    && mkdir --parents --verbose /usr/src/paperless/media \
    && mkdir --parents --verbose /usr/src/paperless/consume \
    && mkdir --parents --verbose /usr/src/paperless/export \
  && echo "Adjusting all permissions" \
    && chown --recursive paperless:paperless /usr/src/paperless \
  && echo "Building translations" \
    && gosu paperless python3 manage.py compilemessages

VOLUME ["/usr/src/paperless/data", \
        "/usr/src/paperless/media", \
        "/usr/src/paperless/consume", \
        "/usr/src/paperless/export"]

ENTRYPOINT ["/sbin/docker-entrypoint.sh"]

EXPOSE 8000

CMD ["/usr/local/bin/paperless_cmd.sh"]
