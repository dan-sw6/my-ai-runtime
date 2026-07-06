# Software Requirements Specification (SRS)
# <Project Name> — v<VERSION>

> Based on IEEE 830/29148, Volere requirement shell, and modern agile practices.
> Adapted for full-stack web applications (API + SPA + database).

## Revision History

| Version | Date | Author | Description |
|---------|------|--------|-------------|

## 1. Introduction

### 1.1 Purpose
<!-- What this document covers. Target audience. -->

### 1.2 Product Scope
<!-- Product name, high-level goals, key benefits. What is NOT in scope. -->

### 1.3 Definitions, Acronyms, Abbreviations
<!-- Domain-specific terms. -->

| Term | Definition |
|------|-----------|

### 1.4 References
<!-- External documents, standards, prior versions. -->

### 1.5 Document Conventions

Requirement ID prefixes (configurable — see `srs.req_id_prefixes` in `runtime.config.yaml`
if this project uses the optional SRS/RTM automation in `story-machinery/srs/`):
- `FR-<MODULE>-NNN` — Functional requirements
- `NFR-<CATEGORY>-NNN` — Non-functional requirements
- `SEC-<CATEGORY>-NNN` — Security requirements

Priority levels (MoSCoW):
- **Must Have** — non-negotiable for release
- **Should Have** — important, workaround exists
- **Could Have** — desirable if time permits
- **Won't Have** — explicitly out of scope this version

Status vocabulary (canonical — drives the optional SRS/RTM automation):
- `not_started` — no implementation yet
- `partial` — in progress / partially delivered
- `implemented` — done and verified; `archive-implemented-srs.py` auto-moves the block
  out of the active SRS into the implemented-archive doc (`srs.archive_path`)
- `deprecated` — requirement withdrawn, kept for history

#### Acceptance criteria notation — EARS

Acceptance criteria are authored in **EARS** (Easy Approach to Requirements Syntax) —
unambiguous, testable sentences that translate directly into test cases. Pick the
pattern that matches the requirement's shape; combine clauses for compound cases
(`WHEN <trigger> WHILE <state> the system SHALL <response>.`):

| Pattern | Form | Use for |
|---------|------|---------|
| Ubiquitous | The system SHALL \<response\>. | Always-true invariants |
| Event-driven | WHEN \<trigger\> the system SHALL \<response\>. | Behavior triggered by an event |
| State-driven | WHILE \<state\> the system SHALL \<response\>. | Behavior throughout a state |
| Conditional | IF \<condition\> THEN the system SHALL \<response\>. | Branching / conditional behavior |
| Unwanted behavior | IF \<condition\> THEN the system SHALL \<response\>. | Error/exception handling paths |
| Optional feature | WHERE \<feature is included\> the system SHALL \<response\>. | Feature-flagged behavior |

> **Automation-reserved markers** (only relevant if `srs.enabled` — see `story-machinery/srs/README.md`):
> `srs-counts.py --write` injects its summary tables between `<!-- srs-counts:start -->` /
> `<!-- srs-counts:end -->` markers — pre-seed an empty pair under whichever section tracks
> implementation-status counts. Without pre-seeded markers it falls back to inserting under
> the first heading matching `## 7`, so keep that section at position 7 if you skip this step.
> `archive-implemented-srs.py` similarly expects a `### Not Started (priority work)` table
> (rows pruned automatically as requirements are archived) and a
> `> **Delivered requirements:** ...` pointer line per category section — both optional,
> add them only if you want that sync.

## 2. Overall Description

### 2.1 Product Perspective
<!-- System context: where this product fits, what it replaces/extends. -->

### 2.2 Product Functions
<!-- High-level capability summary (not detailed requirements). -->

### 2.3 User Classes and Characteristics
<!-- User roles, permissions, experience levels. -->

| User Class | Description | Access Level |
|-----------|-------------|-------------|

### 2.4 Operating Environment
<!-- Runtime: OS, browsers, databases, infrastructure. -->

### 2.5 Design and Implementation Constraints
<!-- Tech stack, regulatory, compatibility constraints. -->

### 2.6 Assumptions and Dependencies
<!-- External systems, third-party services, data availability. -->

## 3. External Interface Requirements

### 3.1 User Interfaces
<!-- Screen inventory, navigation model, responsive breakpoints. -->
<!-- Reference wireframes/mockups if they exist separately. -->

### 3.2 API Contracts
<!-- REST/GraphQL endpoints grouped by domain. -->
<!-- For each endpoint: method, path, auth, request/response schema, errors. -->

### 3.3 Database Interfaces
<!-- Key entities, relationships, migration strategy. -->

### 3.4 External System Interfaces
<!-- Third-party integrations: protocol, data format, sync strategy. -->

### 3.5 Communication Interfaces
<!-- WebSocket, SSE, polling, email, push notifications. -->

## 4. Functional Requirements

<!-- Group by module/feature area. Each requirement uses the shell below. -->

### 4.1 <Module Name>

#### FR-<MOD>-001: <Title>

| Field | Value |
|-------|-------|
| **Status** | not_started |
| **Priority** | Must Have |
| **Description** | The system shall... |
| **Rationale** | Why this requirement exists |
| **Acceptance Criteria** | WHEN \<trigger\> the system SHALL \<response\>. IF \<condition\> THEN the system SHALL \<response\>. |
| **Dependencies** | FR-*, NFR-*, SEC-* |
| **Notes** | Edge cases, constraints |

<!-- **Status** must stay first data row — archive-implemented-srs.py / apply-srs-pending.sh
     insert `| **Verified At** | <date> |` + `| **Story** | STORY-NNN |` right after it once
     Status flips to `implemented`, then move the whole block to the archive doc. -->

<!-- Repeat for each requirement in this module. -->

### 4.2 <Next Module>
<!-- ... -->

## 5. Non-Functional Requirements

### 5.1 Performance (NFR-PERF-*)
<!-- Response time, throughput, concurrent users, page load. -->

### 5.2 Scalability (NFR-SCALE-*)
<!-- Horizontal/vertical scaling, data growth projections. -->

### 5.3 Availability and Reliability (NFR-REL-*)
<!-- Uptime SLA, MTTR, failover, backup/recovery. -->

### 5.4 Usability (NFR-UX-*)
<!-- Accessibility (WCAG level), learnability, error recovery. -->

### 5.5 Maintainability (NFR-MAINT-*)
<!-- Code quality standards, modularity, test coverage targets. -->

### 5.6 Observability (NFR-OBS-*)
<!-- Logging, monitoring, alerting, tracing. -->

## 6. Security Requirements

### 6.1 Authentication and Authorization (SEC-AUTH-*)
<!-- Auth model (JWT, session, OAuth), RBAC/ABAC, MFA. -->

### 6.2 Data Protection (SEC-DATA-*)
<!-- Encryption at rest/in transit, PII handling, data classification. -->

### 6.3 Input Validation (SEC-INPUT-*)
<!-- XSS, CSRF, SQL injection, file upload validation. -->

### 6.4 Audit and Logging (SEC-AUDIT-*)
<!-- What gets logged, retention, tamper protection, compliance. -->

### 6.5 Compliance (SEC-COMP-*)
<!-- OWASP Top 10, regulatory requirements, data residency. -->

## 7. Data Requirements

### 7.1 Data Model
<!-- ERD or key entity descriptions. -->

### 7.2 Data Dictionary

| Entity | Field | Type | Constraints | Description |
|--------|-------|------|-------------|-------------|

### 7.3 Data Migration and Seeding
<!-- Migration strategy, seed data requirements, rollback. -->

### 7.4 Data Retention and Archival
<!-- Retention periods, archival strategy, deletion policy. -->

## 8. UI/UX Specifications

### 8.1 Design System
<!-- Token references, component library, typography, color palette. -->

### 8.2 Screen Inventory

| Route | Page/Component | Description | Requirements |
|-------|---------------|-------------|-------------|

### 8.3 Navigation and Information Architecture
<!-- Menu structure, breadcrumbs, routing model. -->

### 8.4 Responsive and Accessibility
<!-- Breakpoints, WCAG level, keyboard navigation, ARIA. -->

## 9. System Architecture Overview

### 9.1 Component Diagram
<!-- High-level: frontend, backend, database, integrations. -->

### 9.2 Deployment Topology
<!-- Docker, reverse proxy, CI/CD pipeline. -->

### 9.3 Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|

## 10. Risks and Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|

## 11. Appendices

### A. Glossary
### B. Change Log
### C. Open Issues / TBD
