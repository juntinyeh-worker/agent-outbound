# PLX SDK Test Report — 2026-08-14

**Branch:** `sssalim_development_v1.1.X`  
**Version:** 1.1.1  
**Latest Commit:** `174c2a1` — "Update VERSION, portal index, and traces-download handler"  
**Test Environment:** Debian 12 (bookworm), Python 3.12.13, pytest 9.1.1  

---

## Summary

| Level | Description | Passed | Failed | Total |
|-------|-------------|--------|--------|-------|
| **1** | Unit Tests (existing pytest suite) | 822 | 26 | 848 |
| **2** | Integration Smoke Tests | 13 | 0 | 13 |
| **3** | Security Validation | 14 | 1* | 15 |
| **4** | SDK Example Scripts | 3 | 3 | 6 |
| **Total** | | **852** | **30** | **882** |

*\* 1 false positive (regex matched module path `plx_sdk._redaction` as a credential pattern)*

---

## Level 1: Unit Tests (Existing pytest Suite)

**Result:** 822 passed, 26 failed

### Root Cause: SDK Code Generation Drift

The **generated code** (`_actions.py`, `_meta.py`) is **out of sync** with the OpenAPI contract (`docs/openapi/plx-platform-api-v1.yaml`). The SDK implements **54 actions** but the contract defines **94 actions**.

### Failure Breakdown

| Category | Count | Root Cause |
|----------|-------|-----------|
| Missing `WhoAmI` method | 10 | Tests call `who_am_i()` but this action isn't in the generated code |
| Action count mismatch | 1 | SDK has 54 actions, test expects 94 |
| Contract drift detection | 5 | Generated files don't match the contract |
| Missing idempotency actions | 2 | `SimulateTicketEvent`, `ReplyToInvestigation` not generated |
| Missing `RevealPairingWebhookSecret` | 1 | Action not generated |
| Pagination count mismatch | 1 | SDK has 6 paginated actions, test expects 13 |
| Plane count mismatch | 1 | SDK: 36 control + 18 data; contract expects 65 control + 29 data |
| Registry vs contract mismatch | 5 | 5 CODA actions in SDK not in contract + 40 contract actions missing from SDK |

### Fix

```bash
cd plx-sdk-package && python3 tools/generate.py
```

This single command should regenerate `_actions.py` and `_meta.py` and resolve all 26 failures.

### Passing Suites (100%)

- `test_signing.py` — 21/21 (golden vectors, binding, edge cases)
- All 54 implemented actions: method exists, URL routing, field serialization, optional/required field handling, signing, idempotency, response passthrough, scope naming, secret scrubbing, error surfaces

---

## Level 2: Integration Smoke Tests

**Result:** 13/13 PASSED ✓

| Test | Result |
|------|--------|
| Client initialization from params | ✓ |
| Client rejects HTTP URLs | ✓ |
| Client context manager lifecycle | ✓ |
| All 54 actions callable | ✓ |
| All 54 actions POST to correct URL | ✓ |
| All requests carry signed auth block | ✓ |
| Pagination (6 paginated actions) | ✓ |
| Error status mapping (8 codes) | ✓ |
| Idempotency keys (present/absent) | ✓ |
| Flow: run_interaction poll loop | ✓ |
| Client repr hides secrets | ✓ |
| Contract version reported | ✓ |
| Action introspection (actions(), describe_action()) | ✓ |

---

## Level 3: Security Validation

**Result:** 14/15 PASSED (1 false positive)

| Test | Result | Notes |
|------|--------|-------|
| SEC-1: HTTP rejected | ✓ | |
| SEC-1b: HTTPS accepted | ✓ | |
| SEC-2: Secret not in request | ✓ | |
| SEC-2b: No Authorization header | ✓ | |
| SEC-3: Secret not in logs | ✓ | |
| SEC-4: Response field scrubbing | ✓ | 8 field types scrubbed |
| SEC-4b: Nested secret scrubbing | ✓ | |
| SEC-5: Header scrubbing | ✓ | |
| SEC-6: Exceptions don't leak secrets | ✓ | |
| SEC-7: Auth failures not retried | ✓ | 401/403 = 1 attempt only |
| SEC-8: No verify=False in source | ✓ | |
| SEC-9: No unsafe deserialization | ✓ | No pickle/eval/exec |
| SEC-10: No hardcoded credentials | ✗ | **False positive** — regex matched `plx_sdk._redaction` module paths |
| SEC-11: Signing bound to action+params | ✓ | |
| SEC-12: Credential format validation | ✓ | Malformed inputs rejected |

---

## Level 4: SDK Example Scripts

**Result:** 3/6 PASSED

| Test | Result | Notes |
|------|--------|-------|
| Examples directory exists | ✓ | 49 scripts found |
| All scripts valid syntax | ✗ | 10 scripts have syntax errors |
| Imports resolve | ✗ | Blocked by syntax errors |
| Action coverage | ✗ | Blocked by syntax errors |
| run_all.py exists | ✓ | |
| No hardcoded secrets | ✓ | |

### Affected Scripts (Syntax Errors)

All have the same bug — bare comma for actions with no required parameters:

```python
response = client.get_case_creation_binding(
,                          # ← bare comma (invalid Python)
        # account_id="value",,
    )
```

1. `get_case_creation_binding.py`
2. `get_metrics.py`
3. `get_open_api_spec.py`
4. `get_settings.py`
5. `list_connections.py`
6. `list_interactions.py`
7. `list_mcp_keys.py`
8. `list_providers.py`
9. `list_ticket_deliveries.py`
10. `list_traces.py`

### Root Cause

The example generator template emits a bare comma when the required args list is empty. The template produces `(\n,\n` instead of `(\n` for zero-required-arg actions.

---

## Deployment Status

The CloudFormation stack deployment was **blocked** by IAM policy constraints on the sandbox environment:

- CloudFormation stacks must be named `sandbox-*` (template creates `sa-beta-*`)
- DynamoDB tables must be named `sandbox-devtool-*` (template creates `sa-beta-*`)
- Lambda functions must be named `sandbox-*` (template creates `sa-beta-*`)
- No KMS `CreateKey` permission
- API Gateway HTTP APIs (`apigatewayv2:POST /apis`) not allowed

**Resolution needed:** Either expand IAM policies to allow `sa-beta-*` resources, or deploy from an environment with broader permissions.

---

## Recommended Actions

1. **Regenerate SDK code:**
   ```bash
   cd plx-sdk-package && python3 tools/generate.py
   ```
   Resolves all 26 Level 1 failures.

2. **Fix example generator template:**
   Fix the bare-comma bug in `scripts/generate-sdk-docs.py` (or whichever script generates examples) for the zero-required-args case, then regenerate examples.

3. **Deploy the stack:**
   Use an account/role with permissions for `sa-beta-*` named resources, or request IAM policy expansion.

---

## Test Scripts Location

- `test_results/level2_integration_smoke.py` — Level 2 tests (reusable)
- `test_results/level3_security_validation.py` — Level 3 tests (reusable)
- `test_results/level4_sdk_examples.py` — Level 4 tests (reusable)
