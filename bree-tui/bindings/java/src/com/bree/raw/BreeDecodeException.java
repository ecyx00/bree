package com.bree.raw;

/**
 * Unchecked protocol-shape error. Transport and command failures remain
 * checked because callers can recover from them; malformed server data is a
 * broken protocol contract.
 */
public final class BreeDecodeException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public BreeDecodeException(String message, Throwable cause) {
        super(message, cause);
    }
}
