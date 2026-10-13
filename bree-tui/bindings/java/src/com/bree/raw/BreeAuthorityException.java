package com.bree.raw;

/** The client was not configured for the authority required by a command. */
public final class BreeAuthorityException extends BreeException {
    private static final long serialVersionUID = 1L;

    public BreeAuthorityException(String message) {
        super(message);
    }
}
