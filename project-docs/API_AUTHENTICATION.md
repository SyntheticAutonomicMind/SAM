# API Authentication Guide

SAM's API server now requires authentication for all external requests to protect against unauthorized access.

## Security Model

### Internal Requests (SAM UI)
- **No Authentication Required**
- SAM's user interface communicates with the API through direct Swift function calls
- No HTTP requests are made to localhost
- This provides the highest level of security as communication never leaves the process

### External Requests (API Clients)
- **Bearer Token Authentication Required**
- All HTTP requests to the API must include a valid Bearer token
- Tokens are stored in UserDefaults for convenient access
- Only the `/health` endpoint remains public

## Getting Your API Token

1. Open SAM Preferences → API Server
2. Your token is displayed in the "API Authentication" section
3. Click the copy button (📋) to copy it to your clipboard
4. Keep this token secure - it provides full access to your SAM API

## Using the Token

Include your token in the `Authorization` header of all API requests:

```bash
curl -X POST http://localhost:8080/api/chat/completions \
  -H "Authorization: Bearer YOUR-TOKEN-HERE" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Token Management

### Copying Your Token
Click the copy button in Preferences → API Server to copy your token to the clipboard.

### Regenerating Your Token
1. Click the regenerate button (🔄) in Preferences → API Server
2. Confirm the regeneration
3. Update all external clients with the new token
4. Old token is immediately invalidated

### Security Best Practices
- Never share your API token in public repositories or communications
- Regenerate your token if you suspect it has been compromised
- Use environment variables to store tokens in scripts
- Disable "Allow Remote Access" unless you specifically need network access

## Error Responses

### 401 Unauthorized - Missing Token
```json
{
  "error": "Missing Authorization header. API access requires a Bearer token."
}
```

### 401 Unauthorized - Invalid Token
```json
{
  "error": "Invalid API token. Please use the correct token from SAM Preferences → API Server."
}
```

## Remote Access Warning

When "Allow Remote Access" is enabled in Preferences:
- ⚠️ **WARNING**: Your API becomes accessible to anyone on your local network who has your token
- The server binds to `0.0.0.0` instead of `127.0.0.1`
- Only enable this when you need to access SAM from other devices on your network
- Consider using a firewall to restrict access to specific IP addresses

## Implementation Details

### Architecture
- **UserDefaults Storage**: API tokens are stored in UserDefaults for quick access without keychain prompts
- **APITokenMiddleware**: Vapor middleware for token validation with caching
- **Token Format**: Two concatenated UUIDs (e.g., `550e8400-e29b-41d4-a716-446655440000-7c9e6679-7425-40de-944b-e07fc1f90ae7`)

### Security Features
- Token generation uses secure random number generation (UUID)
- Tokens are validated on every request
- Token cached in memory to minimize UserDefaults access
- Internal SAM UI communication bypasses authentication entirely (more secure)
- UserDefaults provides sufficient security for localhost-only API access

### Why Direct Function Calls Are Better

SAM's internal architecture uses direct Swift function calls instead of HTTP:

**SAM UI → SharedConversationService → EndpointManager → Provider**

This design:
- Eliminates HTTP overhead for internal operations
- Prevents token interception or tampering
- Provides the smallest possible attack surface
- Ensures fastest possible response times

External API access via HTTP is only needed for tools like:
- curl scripts
- Python integrations
- VS Code extensions
- Aider and other developer tools

## Migration Notes

For users upgrading from versions without authentication:
- A token is automatically generated on first launch of the new version
- Existing API integrations will need to be updated with the new token
- The token can be found in Preferences → API Server → API Authentication
