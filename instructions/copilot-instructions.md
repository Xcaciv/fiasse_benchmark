# Guidelines for AI‑Generated Developer Documentation in a FIASSE Context

This document defines how AI assistants (e.g., GitHub Copilot, chat-based tools) should generate and refine developer documentation so that it supports **securable** software engineering in line with FIASSE and the Securable Software Engineering Model (SSEM).[^1]

The goal is not just “docs that explain features,” but documentation that helps developers resiliently add computing value while maintaining strong securable attributes: Maintainability, Trustworthiness, and Reliability.[^1]


## 1. Overall Objectives

When generating documentation, always optimize for these outcomes:

- Help developers understand and reason about the system and code (Analyzability).[^1]
- Make it easier and safer to change the system over time (Modifiability).[^1]
- Make the system easier to verify and automate checks for (Testability).[^1]
- Clarify where and how security-relevant behavior occurs (Trustworthiness, Reliability).[^1]

Do not treat security as a separate, after-the-fact section. Instead, weave securable attributes into normal engineering concepts, language, and examples.[^1]


## 2. Default Writing Principles

When producing any documentation (README, ADR, design doc, API docs, in‑repo guides):

- Use established software engineering terms (e.g., “analyzable,” “modular,” “loosely coupled,” “trust boundary”) instead of exploit or tool jargon.[^1]
- Assume the primary audience is developers and engineering leaders, not penetration testers. Focus on “how to build and evolve this safely,” not “how to hack it.”[^1]
- Prefer concrete, system-specific guidance over generic security checklists. Tie advice to actual components, data flows, and code patterns.[^1]

When in doubt, ask: “Does this documentation make it easier for someone to keep this system securable over time?”[^1]


## 3. SSEM Attributes in Documentation

Always try to make documentation explicitly support the three SSEM categories and their sub‑attributes.[^1]

### 3.1 Maintainability: Analyzability, Modifiability, Testability

For every significant module, feature, or API, documentation should improve:

1. **Analyzability** – “How quickly can a new engineer understand this?”[^1]
    - Include purpose, main responsibilities, and key collaborators for each module.
    - Describe high‑level data flows and state transitions (what goes in, what comes out, what persists).[^1]
    - Call out known complexity hotspots and why they exist.
2. **Modifiability** – “How safely can we change this?”[^1]
    - Document extension points, configuration hooks, and known invariants that must not be broken.
    - Explain coupling: which components this one depends on, and which depend on it.[^1]
    - Highlight decisions that are hard to reverse (e.g., persistence schema, public API contracts).
3. **Testability** – “How do we know changes are safe?”[^1]
    - Include a “How to test this” section for significant features: what to unit test, what to integration test, critical edge cases.[^1]
    - Reference existing test suites and patterns (e.g., example test files, fixtures, mocks).
    - Describe how to simulate important failure modes and security-relevant paths.[^1]

When generating or editing docs, explicitly add short subsections or callouts for these aspects where they are missing.


### 3.2 Trustworthiness: Confidentiality, Accountability, Authenticity

Documentation must help developers understand **how the system is trustworthy**, not just what controls exist.[^1]

1. **Confidentiality** – “What must not leak, and where?”[^1]
    - Identify sensitive data handled by the component (e.g., PII, credentials, financials).
    - Clearly state where data is stored, where it transits, and where it is exposed externally.[^1]
    - Document any redaction, masking, and encryption expectations at boundaries.
2. **Accountability** – “Can we trace who did what?”[^1]
    - Describe which user or system actions are logged, and where logs live.[^1]
    - Specify the expected log content for critical events (who/what/when/where/why).[^1]
    - Clarify log retention and access expectations, especially for security-sensitive actions.
3. **Authenticity** – “Are entities and messages what they claim to be?”[^1]
    - Document authentication flows (user and service-to-service), including identity sources.[^1]
    - Note where digital signatures, tokens, or certificates are required and how they are validated.[^1]
    - Capture assumptions about trust: which callers or upstreams are considered trusted, partially trusted, or untrusted.

When generating documentation around auth, logging, or data access, always make these authenticity and accountability aspects explicit.


### 3.3 Reliability: Availability, Integrity, Resilience

Docs should help teams design and operate systems that behave predictably under stress and attack.[^1]

1. **Availability** – “How do we stay up?”[^1]
    - Describe dependencies (databases, queues, external APIs) and what happens when they are slow or unavailable.[^1]
    - Document any rate limits, backoff strategies, and failover mechanisms that exist or are expected.
2. **Integrity** – “How do we keep state and calculations correct?”[^1]
    - Explain which values are derived on the server vs. accepted from clients (e.g., Derived Integrity Principle for prices, permissions, statuses).[^1]
    - Point out any invariants that must always hold (e.g., state transitions that are forbidden).[^1]
3. **Resilience** – “How does the system behave under failure or abuse?”[^1]
    - Document how the component should respond to invalid or malicious inputs (ignore, reject, sanitize, throttle).[^1]
    - Describe error handling strategy: what is logged, what is surfaced to users, what is retried.[^1]
    - Include guidance for chaos or failure injection where relevant.

When AI generates “operational” or “runbook” style docs, it should explicitly tie steps back to these reliability concerns.


## 4. Transparency as a Documentation First-Class Citizen

Transparency is a foundational principle in FIASSE: systems should be observable and understandable to authorized parties.[^1]

When generating documentation:

- Always clarify what is **observable** (logs, metrics, traces, dashboards) for the feature.[^1]
- Describe how to correlate user actions with system behavior (e.g., key log fields, IDs, trace propagation).[^1]
- Encourage structured logging and explicit metrics as part of examples and code snippets.[^1]

For example, when documenting an API endpoint that changes user permissions, include:

- Expected audit log entries and fields.
- Metrics that should increase or alert when unusual activity occurs.[^1]

This makes the system more analyzable for both debugging and security investigations.


## 5. Threat Modeling Hooks in Docs

FIASSE encourages simple, iterative threat modeling that fits naturally into development, such as the “Four Question Framework.”[^1]

When generating design or architecture documentation, the assistant should include a short section that addresses:

1. What are we building? (system purpose, key data, main actors)[^1]
2. What can go wrong? (focus on data flows and trust boundaries, not just generic attack lists)[^1]
3. What are we going to do about it? (link to SSEM attributes and specific design choices)[^1]
4. Did we do a good job? (how this will be validated – tests, reviews, observability)[^1]

Use SSEM attributes to express mitigations. For example:

- “We reduce tampering risk by enforcing Derived Integrity for pricing calculations (Integrity).”[^1]
- “We limit blast radius by isolating this function behind a strong trust boundary with strict input validation (Resilience, Integrity).”[^1]


## 6. AI Prompting and Guardrails for Documentation

When you (the AI assistant) are asked to generate or extend developer documentation in this repository:

1. **Always:**
    - Reflect SSEM attributes explicitly where meaningful (e.g., “Analyzability,” “Integrity,” “Resilience” subsections or callouts).[^1]
    - Use examples consistent with existing FIASSE language and analogies where appropriate (e.g., trust boundaries, request surface minimization).[^1]
    - Assume documentation will be read by developers who will maintain this code for years, not just complete a sprint.
2. **Never:**
    - Recommend practices that contradict core FIASSE principles (e.g., trusting client-supplied critical values, opaque behavior with no logging around security-sensitive actions).[^1]
    - Frame security solely as passing tools or audits; instead, emphasize long-term securability of the system.[^2]
3. **Prefer to:**
    - Tie documentation guidance to concrete code artifacts: modules, packages, endpoints, message schemas, configuration files.[^1]
    - Highlight where additional security requirements or acceptance criteria should be formalized (e.g., in `prd.md`, `acd.md`).[^1]

Recommended meta‑prompt for this repo (conceptual):

> “When generating documentation, ensure it improves SSEM attributes (Maintainability, Trustworthiness, Reliability), makes security-relevant behavior transparent, and provides specific, actionable guidance for long-term securability of this system.”[^1]


## 7. Where to Embed FIASSE/SSEM in Docs

When adding or updating docs, the assistant should look for or propose:

- **In PR templates / merge documentation:**
    - Short checklist or questions around Analyzability, Trustworthiness, Reliability for the change.[^1]
- **In feature/architecture docs:**
    - A small “SSEM Considerations” section, mapping key design decisions to SSEM attributes.[^1]
- **In runbooks / ops guides:**
    - Clear, step-by-step instructions aligned to Reliability and Accountability (e.g., how to trace an incident, which logs/metrics to consult).[^1]
- **In API docs:**
    - For each endpoint: data sensitivity level, trust boundary crossing, and expectations for input validation and logging.[^1]


## 8. Tone and Perspective

Documentation should reflect the FIASSE mindset:

- Developer‑centric, assuming engineers are partners in security, not targets of security “gotchas.”[^1]
- Focused on building software that is hard to break and easy to fix, instead of glorifying vulnerability hunting.[^2]
- Treating security as a natural property of good software engineering practice, not a separate, opaque discipline.[^1]

When you generate documentation, speak to developers as responsible owners of a long‑lived product, not temporary feature implementers.[^2]

[^1]: FIASSE-RFC.md

[^2]: Sister-Practices-for-Sustainable-Defen.md

