---
name: technical-presentation
description: Use when supplied architecture, engineering, incident, technology-comparison, test, API, or technical-talk material must become a clear explanation of mechanisms, trade-offs, validation, and next steps.
products: [pptx]
---

# Technical and Engineering Presentation

## Core Character

Build pages around architectures, flows, sequences, data, comparisons, code, screenshots, and supplied technical material. Use text to explain the reason for a choice and visuals to reveal the relationships.

Make the system concrete. Show supplied inputs, outputs, boundaries, dependencies, success criteria, normal paths, exception paths, fallback paths, failure conditions, and recovery paths. Place costs beside benefits and operating conditions beside recommendations.

## Reference Structures

### Applied engineering talk

Begin with the operational problem, impact, or constraint. Explain the mechanism that produced it, then show the system choice, its trade-offs, the rollout or recovery path, and the measured result. Close with the remaining limits and the conditions under which the lesson applies.

For an incident, use impact, timeline, direct mechanism, contributing system factors, corrective changes, and validation. Keep observations, decisions, and effects attached to the events where they occurred.

### Systems research talk

Move from problem and constraints to design principles, architecture, key mechanisms, implementation, evaluation, and limitations. Introduce the whole system before expanding one mechanism at a time. Keep each evaluation page tied to the design claim it tests.

## Narrative Skeletons

| Engineering task | What the reader must judge | Recommended sequence |
|---|---|---|
| System architecture review | Whether boundaries, dependencies, bottlenecks, and evolution are sound | Goals and constraints → current state → problems → alternatives → target architecture → migration and validation |
| AI or data platform proposal | How data, models, and services work together | User tasks → data and model pipeline → mechanisms → evaluation → operating limits → launch loop |
| Security design review | Whether boundaries, attack paths, controls, and residual risk are clear | Assets and boundaries → threats → attack paths → controls → residual risk → monitoring and response |
| Production incident review | What happened and whether the changes address it | Impact → timeline → direct mechanism → contributing factors → changes → validation |
| Technology selection | Which option fits the goals and what assumptions affect the choice | Goals and criteria → candidates → comparison → trade-offs → recommendation → exit conditions |
| Test and validation strategy | Whether risks and release gates have enough coverage | Risk model → validation layers → environment and data → gates → gaps → release decision |
| External technical talk | Why the mechanism matters and where it applies | Problem → mechanism → implementation → results → limitations → adoption path |

## Page Rhythm

Keep one main judgment and one main visual object per page. Introduce a complete architecture first, then expand layers or paths over several pages with stable coordinates. Keep unchanged parts in place and highlight what changes.

Alternate explanation pages with architecture, comparison, benchmark, code, or screenshot pages when the audience needs context before detail. End by returning to the decision, validation result, operating lesson, or next step.

### Common page types

- **Concept page:** pair the necessary explanation with one main figure.
- **Architecture page:** let the diagram dominate; keep the conclusion, legend, and side notes close to it.
- **Comparison page:** compare options on the same dimensions, scale, and coordinates.
- **Benchmark page:** lead with the chart; keep environment, baseline, units, and conclusion beside it.
- **Incident page:** use chronology as the main axis and attach observations and actions to their events.
- **Implementation page:** show phases, dependencies, gates, rollback points, and recovery paths in their actual relationships.
- **Appendix page:** use stable columns, numbering, and line spacing to keep dense detail scannable.

## Diagram Grammar

| Relationship | Graphic | Information to keep visible |
|---|---|---|
| System regions and boundaries | Nested or side-by-side regions | Scope, external dependencies, trust and failure boundaries |
| Calls and data flow | Directed node chain or network | Caller, callee, protocol or data, sync or async behavior |
| Multi-role interaction | Sequence diagram | Roles, messages, waits, and exception branches |
| Deployment and failure domains | Topology diagram | Regions, clusters, instances, redundancy, and isolation scope |
| State transitions | State machine | States, trigger conditions, transitions, and error states |
| Option comparison | Parallel topologies or matrix | Common dimensions, structural differences, and costs |
| Incident causality | Timeline with causal chain or fault tree | Events, observations, causes, contributing factors, and control gaps |
| Validation coverage | Layered matrix or mapping diagram | Risks, test layers, pass criteria, and gaps |

Give every arrow a direction and meaning. Label protocol, data, frequency, capacity, or trigger conditions when they matter. Distinguish data flow, control flow, and exception paths with stable line, label, or color semantics. Terminate connectors at node edges and keep them away from text.

For complex systems, show the overview first and then zoom into details. Preserve names, boundaries, coordinates, and visual semantics across the sequence.

## Charts, Tables, Code, and Screenshots

- Use charts that match the supplied data shape. Label key values, changes, and anomalies directly, with their meaning close to the mark.
- Keep test environment, version, load, sample, units, and baseline beside the result when supplied.
- Compare options in tables on the same dimensions. Align numbers and units consistently, and preserve markers for missing or non-comparable values.
- Show only the code, configuration, log, or interface excerpt needed for the local argument. Tell the reader what to inspect before presenting the excerpt.
- Use a minimal diff for configuration changes and keep supplied timestamps and component names in logs.
- Crop screenshots to the relevant area. Keep compared screenshots at the same zoom, size, and baseline.

## Review

Before delivery, confirm that inputs, outputs, dependencies, boundaries, normal paths, exception paths, and fallback paths are clear where the material includes them. Check that current state, target state, alternatives, and supplied results remain visually distinct. Read the page titles alone and confirm that they preserve the technical argument from problem through mechanism and validation to the final decision or lesson.
