"""RFC 9562 UUIDv7 IDs, generated in the application without a DB extension."""
import secrets
import os
import threading
import time
from uuid import UUID

_lock = threading.Lock()
_last_ms = -1
_random = 0
_pid = os.getpid()


def _reset_after_fork():
    global _lock, _last_ms, _pid
    _lock = threading.Lock()
    _last_ms = -1
    _pid = os.getpid()


if hasattr(os, 'register_at_fork'):
    os.register_at_fork(after_in_child=_reset_after_fork)


def uuid7() -> UUID:
    """Monotonic within this process, including clock rollback; random across processes."""
    global _last_ms, _random, _pid
    with _lock:
        if _pid != os.getpid():
            _pid = os.getpid()
            _last_ms = -1
        now = max(time.time_ns() // 1_000_000, _last_ms)
        if now == _last_ms:
            _random += 1
            if _random >= 1 << 74:
                now += 1
                _random = secrets.randbits(74)
        else:
            _random = secrets.randbits(74)
        _last_ms = now
        return UUID(int=(now << 80) | (7 << 76) | ((_random >> 62) << 64)
                    | (2 << 62) | (_random & ((1 << 62) - 1)))
