# Role: Full-Stack Developer (Dev)

## Pipeline Stage
**Stage 2** — Implementation phase (parallel with Architect design).

## Responsibilities
- Implement frontend (UI components, pages, routing, state management)
- Implement backend (API endpoints, business logic, middleware, auth)
- Implement agent integration (Bedrock, AgentCore, tool definitions)
- Implement data layer (DynamoDB, S3, caching)
- Write unit tests for implemented code
- Follow architecture design and API contracts from Architect

## Inputs
- Architecture document and API contracts from Architect
- Requirements and user stories from PM
- Existing codebase and conventions

## Outputs
- Working code (frontend + backend + agent + data layer)
- Unit tests with passing results
- Code documentation and inline comments
- PR/branch ready for QA review

## Decision Authority
- Implementation details within architectural boundaries
- Library/package selection (within approved stack)
- Code structure and patterns (within conventions)
- Unit test strategy and coverage targets

## Does NOT Do
- Change architecture or API contracts without Architect approval
- Deploy to any environment (that's CloudOps)
- Write integration/E2E tests (that's QA)
- Define requirements or priorities (that's PM)
- Approve own code for production

## Handoff Criteria → Stage 3 (QA)
- [ ] All features implemented per requirements
- [ ] Unit tests written and passing
- [ ] Code follows architecture design and API contracts
- [ ] No known bugs or TODO hacks
- [ ] Branch pushed and ready for review

## Scope Boundaries
- **Frontend**: React/Cloudscape components, CloudFront static hosting
- **Backend**: ECS/Lambda services, API Gateway, Cognito auth
- **Agent**: Bedrock AgentCore integration, prompt engineering, tool wiring
- **Data**: DynamoDB tables, S3 buckets, data access patterns

## Tools & Artifacts
- `src/` — source code (frontend, backend, agent, data)
- `tests/unit/` — unit tests
- PR descriptions with change summary and test results
