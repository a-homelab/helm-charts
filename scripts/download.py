import hashlib
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

ATTEMPTS = 4


def cached_download(url, path, sha256, timeout=120):
    """Return the bytes of a checksum-pinned file, downloading it into path once.

    CI fetches upstream CRDs and schemas on every run, and a single connection
    reset used to fail the whole job, so transient network errors are retried.
    The file reaches path only after it matches sha256, so an interrupted or
    tampered download never poisons the cache.
    """
    path = Path(path)
    if not path.exists():
        for attempt in range(1, ATTEMPTS + 1):
            try:
                with urlopen(url, timeout=timeout) as response:
                    data = response.read()
                break
            except (URLError, OSError):
                if attempt == ATTEMPTS:
                    raise
                time.sleep(2**attempt)
        if hashlib.sha256(data).hexdigest() != sha256:
            raise ValueError(f"Upstream checksum mismatch: {url}")
        partial = path.with_name(path.name + ".partial")
        partial.write_bytes(data)
        partial.replace(path)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError(f"Cached checksum mismatch: {path}")
    return data
