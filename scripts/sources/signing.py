"""Signing comes from the source when it is explicitly supplied."""
def status(value):
    return "signed" if value is True else "unsigned" if value is False else "unknown"
