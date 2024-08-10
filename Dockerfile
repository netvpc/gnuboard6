# Base image for building the environment
FROM python:3.12 AS env-builder

# Install Rust with a specific toolchain and set up environment variables
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs/ | sh -s -- --default-toolchain=1.68.0 -y && \
    echo 'source $HOME/.cargo/env' >> $HOME/.bashrc
ENV PATH "$HOME/.cargo/bin:$PATH"
RUN source $HOME/.cargo/env
## TODO: Use gosu
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
