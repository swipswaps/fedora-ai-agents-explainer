# Build a current, hash-verified SQLite shared library separately from the runtime.
# SQLite upstream release/checksum reference: https://www.sqlite.org/download.html
# FTS5 build configuration reference: https://www.sqlite.org/fts5.html
# Python sqlite3 extension-loading API: https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.enable_load_extension
# Debian stable can ship an older SQLite patch level; the application database
# uses the upstream 3.54.1 release with FTS5, JSON1 and loadable extensions.
FROM python:3.12-slim-trixie AS sqlite-build
ARG SQLITE_VERSION=3540100
ARG SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl make && \
    curl --fail --location --silent --show-error \
      "https://www.sqlite.org/2026/sqlite-autoconf-${SQLITE_VERSION}.tar.gz" \
      --output /tmp/sqlite-autoconf.tar.gz && \
    printf '%s  %s\n' "$SQLITE_SHA256" /tmp/sqlite-autoconf.tar.gz | sha256sum -c - && \
    tar -xzf /tmp/sqlite-autoconf.tar.gz -C /tmp && \
    cd "/tmp/sqlite-autoconf-${SQLITE_VERSION}" && \
    ./configure --prefix=/opt/sqlite --enable-fts5 && \
    make -j"$(nproc)" && make install

FROM python:3.12-slim-trixie AS runtime
COPY --from=sqlite-build /opt/sqlite/lib/ /opt/sqlite/lib/
ENV LD_LIBRARY_PATH=/opt/sqlite/lib PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN python -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3,54,1), sqlite3.sqlite_version; c=sqlite3.connect(":memory:"); c.execute("CREATE VIRTUAL TABLE fts_check USING fts5(content)"); assert c.execute("SELECT json_valid(?)", ("{\"ok\":true}",)).fetchone()[0] == 1; c.enable_load_extension(True); c.enable_load_extension(False); c.close(); print("Verified SQLite", sqlite3.sqlite_version, "with FTS5, JSON1 and extension loading")'
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --upgrade pip && python -m pip install -r /app/requirements.txt
COPY . /app
RUN useradd --create-home --uid 10001 appuser && mkdir -p /data && chown -R appuser:appuser /app /data
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=20s --timeout=5s --start-period=15s --retries=4 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-server-header"]
