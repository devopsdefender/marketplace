import hashlib

# TODO: Replace with real HD wallet integration.
# In production, derive addresses from a BIP-32 seed stored at /data/wallet.dat
# inside the TDX enclave so keys never leave hardware.

_address_counter = 0


def generate_address():
    """Generate a unique placeholder BTC address."""
    global _address_counter
    _address_counter += 1
    h = hashlib.sha256(f"placeholder-{_address_counter}".encode()).hexdigest()[:32]
    return f"bc1q{h}"


def check_payment(address):
    """Check if a payment has been received at the given address.

    Stub: always returns False. Use the /api/invoices/<id>/simulate-payment
    endpoint during development.
    """
    # TODO: Query a Bitcoin node or block explorer API
    return False
