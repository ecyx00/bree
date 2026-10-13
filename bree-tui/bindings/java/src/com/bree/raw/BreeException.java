package com.bree.raw;

public class BreeException extends Exception {
    private static final long serialVersionUID = 1L;

    public BreeException(String message) {
        super(message);
    }

    public BreeException(String message, Throwable cause) {
        super(message, cause);
    }
}
