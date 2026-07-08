# XNAT JupyterHub Integration Fixes (2026-04-08)

## Problem

Jupyter notebook sessions launched from XNAT failed to start, presenting users with a 500 Internal Server Error.

## Root Causes

Three separate issues were identified, each blocking notebook launch:

### 1. Stale stopped named servers blocking new launches

**Symptom:** `400 POST` — "User stanford_sciget already has the maximum of 2 named servers."

XNAT creates timestamped named servers (e.g. `20260404T021032691Z`) each time a user launches a notebook. JupyterHub is configured with `named_server_limit_per_user: 2`. When an idle culler stops these servers, it must also remove them from the JupyterHub database. Otherwise stopped-but-not-removed servers still count against the limit and block new launches.

**Fix:** Added `cull.removeNamedServers: true` for the chart-managed culler and `--remove-named-servers` to the `user-cull` service command. Manually clean up existing stale servers via the JupyterHub API using `DELETE /api/users/{name}/servers/{server_name}` with `{"remove": true}` in the request body (the `remove` flag must be in the JSON body, not a query parameter; without it, the DELETE only stops the server but does not remove the database record).

### 2. Username mapping missing for token API handlers

**Symptom:** `403 POST` — "Service sciget not found or no permissions to generate tokens", then `400 POST` — "Not assigning requested scopes access:servers!user=sciget not held by User stanford_sciget"

XNAT sends API requests using the XNAT username (`sciget`), but JupyterHub stores users with a provider prefix (`stanford_sciget`). The existing `02_username_normalization` config in `extraConfig` had monkey-patched `UserAPIHandler` and `UserServerAPIHandler` to map usernames, but did NOT patch the token handlers:

- `UserTokenListAPIHandler` — used by XNAT to create API tokens for users
- `UserTokenAPIHandler` — used to manage individual tokens

Additionally, when XNAT requests a token with scoped permissions like `access:servers!user=sciget`, the scope string also contains the unmapped username. The scope must be rewritten to `access:servers!user=stanford_sciget` before passing to JupyterHub's token creation logic.

**Fix:** Added wrappers for `UserTokenListAPIHandler.get/post` and `UserTokenAPIHandler.get/delete` in `02_username_normalization`. The `token_list_post_wrapper` also rewrites `!user={xnat_name}` to `!user={jupyterhub_name}` in the request body's `scopes` array.

### 3. Browser token authentication not working (OIDC fallback failing)

**Symptom:** `500 GET /jupyter/hub/oauth_callback` — Stanford token endpoint returns `{"error": "invalid_request", "error_description": "InvalidEvent"}`

The XNAT JupyterHub plugin flow is:
1. Create a named server via JupyterHub API
2. Create an API token for the user via JupyterHub API
3. Redirect the user's browser to the notebook URL with `?token=...`

In step 3, JupyterHub should authenticate the user using the token from the URL. However, JupyterHub 5.x's web page handlers (`@web_authenticated`) only check cookies — they do not check for API tokens in URL query parameters. Without a valid session cookie, JupyterHub falls back to OIDC login with Stanford.

The OIDC fallback itself fails because Stanford's Shibboleth OIDC implementation rejects the PKCE token exchange with "InvalidEvent" (likely a compatibility issue between oauthenticator 17.4.0's PKCE implementation and Stanford's Shibboleth IdP). Note: PKCE cannot be disabled — Stanford requires it (`400: PKCE code challenge required`).

**Fix:** Added `03_token_auth_handler` in `extraConfig` that monkey-patches `BaseHandler.get_current_user` (an **async** method in JupyterHub 5.x — using a sync function silently fails). The patched method:
1. First tries normal cookie-based authentication (calls the original `get_current_user`)
2. If no cookie session exists, checks for a `token` query parameter
3. Looks up the token in the database via `orm.APIToken.find()`
4. If valid, sets a login cookie for the user and returns the user object

This bypasses the OIDC flow entirely when the user arrives from XNAT with a valid token.

## Key Learnings

- **JupyterHub 5.x async handlers:** `BaseHandler.get_current_user` is an `async` method. Monkey-patching with a sync function silently fails — the handler returns `None` and falls through to OIDC login. Must use `async def`.

- **Removing stopped named servers:** `DELETE /api/users/{name}/servers/{server_name}` only stops a running server by default. To actually remove a stopped server from the database, send `{"remove": true}` in the request body. The `?remove=true` query parameter does NOT work.

- **Stanford Shibboleth PKCE:** Stanford's OIDC endpoint requires PKCE (S256) but the token exchange fails with oauthenticator 17.4.0's PKCE implementation ("InvalidEvent" error). This remains unresolved — the token auth handler workaround avoids the OIDC flow for XNAT-initiated sessions. Direct JupyterHub login via Stanford OIDC may still be affected.

## Files Changed

- `jupyterhub/5-jupyterhub-values.yaml`:
  - Added `cull.removeNamedServers: true` for the chart-managed idle culler
  - Added `--remove-named-servers` to user-cull service
  - Line 126: Added `UserTokenListAPIHandler, UserTokenAPIHandler` imports
  - Lines 278-318: Token handler wrappers with scope rewriting
  - Lines 320-341: Async `get_current_user` patch for URL token auth

## Remaining Issues

- **Stanford OIDC PKCE incompatibility:** Direct login to JupyterHub via Stanford OIDC (not via XNAT) will still fail with the "InvalidEvent" error. This only affects users navigating directly to `/jupyter/` — XNAT-initiated notebook launches use the token auth bypass.

- No known remaining issue with XNAT-initiated JupyterHub launches after the fixes above.
