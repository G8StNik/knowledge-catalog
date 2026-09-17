"""Request transaction helper. Ticket issuance belongs to a trusted authentication broker."""
from contextlib import contextmanager


@contextmanager
def tenant_transaction(conn, ticket):
    """Start from an idle pooled connection; context is cleared on commit or rollback."""
    from psycopg.pq import TransactionStatus
    if conn.info.transaction_status != TransactionStatus.IDLE:
        raise ValueError('Tenant requests require an idle connection; nested contexts are unsafe')
    with conn.transaction():
        conn.execute('SELECT security.begin_context(%s)',(ticket,))
        yield conn
