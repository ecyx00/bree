package com.bree.raw;

/** The server sent more pre-acknowledgement events than the configured stream buffer allows. */
public final class BreeStreamBufferOverflowException extends BreeException {
    private static final long serialVersionUID = 1L;

    private final int limit;

    public BreeStreamBufferOverflowException(int limit) {
        super("pre-acknowledgement stream event buffer exceeds configured limit " + limit);
        this.limit = limit;
    }

    public int limit() {
        return limit;
    }
}
