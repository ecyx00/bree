package com.bree.raw;

public final class BreeTransportException extends BreeException {
    private static final long serialVersionUID = 1L;

    public BreeTransportException(String message, Throwable cause) {
        super(message, cause);
    }

    public BreeTransportException(String message) {
        super(message);
    }
}
