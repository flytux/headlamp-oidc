package com.example.authserver.security;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.security.authentication.event.AbstractAuthenticationFailureEvent;
import org.springframework.security.authentication.event.AuthenticationSuccessEvent;
import org.springframework.stereotype.Component;

@Component
public class AuthEventLogger {

    private static final Logger log = LoggerFactory.getLogger(AuthEventLogger.class);

    @EventListener
    public void onAuthSuccess(AuthenticationSuccessEvent event) {
        log.info("Authentication success: principal={}, details={}", event.getAuthentication().getName(), event.getAuthentication().getDetails());
    }

    @EventListener
    public void onAuthFailure(AbstractAuthenticationFailureEvent event) {
        log.warn("Authentication failure: principal={}, reason={}", event.getAuthentication().getName(), event.getException().getMessage());
    }
}
