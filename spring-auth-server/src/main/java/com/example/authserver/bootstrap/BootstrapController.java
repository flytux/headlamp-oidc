package com.example.authserver.bootstrap;

import jakarta.validation.Valid;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/bootstrap")
public class BootstrapController {

    private final BootstrapRegistrationService bootstrapRegistrationService;
    private final String bootstrapAdminToken;

    public BootstrapController(
        BootstrapRegistrationService bootstrapRegistrationService,
        @Value("${bootstrap.admin-token}") String bootstrapAdminToken
    ) {
        this.bootstrapRegistrationService = bootstrapRegistrationService;
        this.bootstrapAdminToken = bootstrapAdminToken;
    }

    @PostMapping("/registrations")
    @ResponseStatus(HttpStatus.CREATED)
    public BootstrapRegistrationResponse register(
        @RequestHeader("X-Bootstrap-Token") String bootstrapToken,
        @Valid @RequestBody BootstrapRegistrationRequest request
    ) {
        if (!bootstrapAdminToken.equals(bootstrapToken)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "invalid bootstrap token");
        }

        return bootstrapRegistrationService.register(request);
    }
}
