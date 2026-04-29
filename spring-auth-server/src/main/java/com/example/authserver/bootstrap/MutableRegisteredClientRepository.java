package com.example.authserver.bootstrap;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClientRepository;

public class MutableRegisteredClientRepository implements RegisteredClientRepository {

    private final Map<String, RegisteredClient> clientsById = new ConcurrentHashMap<>();
    private final Map<String, String> clientIdsToIds = new ConcurrentHashMap<>();

    @Override
    public void save(RegisteredClient registeredClient) {
        RegisteredClient existing = findByClientId(registeredClient.getClientId());
        if (existing != null && !existing.getId().equals(registeredClient.getId())) {
            clientsById.remove(existing.getId());
        }

        clientsById.put(registeredClient.getId(), registeredClient);
        clientIdsToIds.put(registeredClient.getClientId(), registeredClient.getId());
    }

    @Override
    public RegisteredClient findById(String id) {
        return clientsById.get(id);
    }

    @Override
    public RegisteredClient findByClientId(String clientId) {
        String id = clientIdsToIds.get(clientId);
        return id == null ? null : clientsById.get(id);
    }
}
