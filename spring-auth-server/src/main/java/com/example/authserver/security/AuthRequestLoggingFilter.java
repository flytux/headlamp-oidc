package com.example.authserver.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Map;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.lang.NonNull;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class AuthRequestLoggingFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(AuthRequestLoggingFilter.class);

    @Override
    protected boolean shouldNotFilter(@NonNull HttpServletRequest request) {
        String path = request.getRequestURI();
        return !(path.startsWith("/oauth2/authorize") || path.startsWith("/oauth2/token") || path.startsWith("/oauth2/revoke"));
    }

    @Override
    protected void doFilterInternal(
        @NonNull HttpServletRequest request,
        @NonNull HttpServletResponse response,
        @NonNull FilterChain filterChain
    )
        throws ServletException, IOException {

        String params = request.getParameterMap().entrySet().stream()
            .collect(Collectors.toMap(Map.Entry::getKey, e -> sanitize(e.getKey(), e.getValue())))
            .toString();

        log.info("OIDC auth request: method={}, path={}, params={}", request.getMethod(), request.getRequestURI(), params);
        filterChain.doFilter(request, response);
        log.info("OIDC auth result: method={}, path={}, status={}", request.getMethod(), request.getRequestURI(), response.getStatus());
    }

    private String sanitize(String key, String[] values) {
        if ("client_secret".equals(key) || "password".equals(key)) {
            return "[REDACTED]";
        }
        return String.join(",", values);
    }
}
