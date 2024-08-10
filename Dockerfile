# Base image for building the environment
FROM python:3.12 AS env-builder

# Install Rust with a specific toolchain and set up environment variables
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    RUST_VERSION=1.80.1

RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) rustArch='x86_64-unknown-linux-gnu'; rustupSha256='6aeece6993e902708983b209d04c0d1dbb14ebb405ddb87def578d41f920f56d' ;; \
        armhf) rustArch='armv7-unknown-linux-gnueabihf'; rustupSha256='3c4114923305f1cd3b96ce3454e9e549ad4aa7c07c03aec73d1a785e98388bed' ;; \
        arm64) rustArch='aarch64-unknown-linux-gnu'; rustupSha256='1cffbf51e63e634c746f741de50649bbbcbd9dbe1de363c9ecef64e278dba2b2' ;; \
        i386) rustArch='i686-unknown-linux-gnu'; rustupSha256='0a6bed6e9f21192a51f83977716466895706059afb880500ff1d0e751ada5237' ;; \
        ppc64el) rustArch='powerpc64le-unknown-linux-gnu'; rustupSha256='079430f58ad4da1d1f4f5f2f0bd321422373213246a93b3ddb53dad627f5aa38' ;; \
        s390x) rustArch='s390x-unknown-linux-gnu'; rustupSha256='e7f89da453c8ce5771c28279d1a01d5e83541d420695c74ec81a7ec5d287c51c' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.27.1/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
    rustup --version; \
    cargo --version; \
    rustc --version;

# Set up a user for the environment
ENV USER=g6
RUN useradd --create-home --shell /bin/bash ${USER}

# Set working directory
WORKDIR /g6

# Clone the repository and remove unwanted files
RUN git clone --recurse-submodules -j8 --depth 1 https://github.com/gnuboard/g6.git . && \
    find . -mindepth 1 -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec bash -c 'echo "Deleting {}"; rm -rf {}' \;

# Set ownership of the working directory
RUN chown -R ${USER}:${USER} /g6

# Install dependencies and essential build tools
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get -y --no-install-recommends install \
        locales \
        tini \
        cmake \
        ninja-build \
        build-essential \
        g++ \
        gobjc \
        meson \
        openssl \
        libssl-dev \
        libffi-dev \
        liblapack-dev \
        libblis-dev \
        libblas-dev \
        libopenblas-dev

# Configure locale settings
RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales

# Set up Python virtual environment and install Python dependencies
RUN --mount=type=tmpfs,target=/root/.cargo \
    python3 -m venv /venv && \
    /venv/bin/python3 -m pip install --upgrade pip && \
    /venv/bin/python3 -m pip install cython && \
    /venv/bin/python3 -m pip install -r requirements.txt && \
    find . -type f \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) -exec bash -c 'echo "Deleting {}"; rm -f {}' \;

# Final lightweight image
FROM python:3.12-slim-bookworm AS final

# Set up a user for the final image
ENV GOSU_VERSION=1.17 \
    USER=g6

RUN useradd --create-home --shell /bin/bash ${USER}

RUN set -eux; \
      # save list of currently installed packages for later so we can clean up
          savedAptMark="$(apt-mark showmanual)"; \
          apt-get update; \
          apt-get install -y --no-install-recommends ca-certificates gnupg wget; \
          rm -rf /var/lib/apt/lists/*; \
          \
          dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
          wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
          wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
          \
      # verify the signature
          export GNUPGHOME="$(mktemp -d)"; \
          gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
          gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
          gpgconf --kill all; \
          rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
          \
      # clean up fetch dependencies
          apt-mark auto '.*' > /dev/null; \
          [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
          apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
          \
          chmod +x /usr/local/bin/gosu; \
      # verify that the binary works
          gosu --version; \
          gosu nobody true

# Copy files and set permissions
COPY --from=env-builder --chown=${USER}:${USER} /g6 /g6
COPY --from=env-builder --chown=${USER}:${USER} /venv /venv
COPY --from=env-builder --chown=${USER}:${USER} /usr/bin/tini /usr/bin/tini
COPY start.sh /usr/local/bin/

# Set working directory
WORKDIR /g6

# Set up a volume
VOLUME /g6

# Expose the application port
EXPOSE 8000

# Entry point for the container
ENTRYPOINT ["tini", "--", "start.sh"]

# Default command to run the application
CMD ["/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
