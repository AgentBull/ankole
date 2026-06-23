# Elixir skill for Claude

This is a rather ambitious project to make Claude do idiomatic Elixir both in architecture and code. The skill has a hub structure with a core skill aiming to cover the most crucial and daily bits, and with referenced supporting files covering more specialized topics. Only the core skill is loaded into the context when the skill is invoked. 

So far I've only sanitized this and the rust-nif skill. Other related skills might follow time and motivation permitting. 





## **Install**  

git clone git@github.com:BadBeta/Elixir_skill.git  ~/.claude/skills/elixir

(Might have to restart Claude terminal to pick it up). 

**To update later:**

cd ~/.claude/skills/elixir && git pull





## First project prompt

The first prompt should ensure that the skill is used during planning. Agents do not use skills so they have to be avoided.  Claude will also sometimes choose to ignore skills even if it says always use in the skill, so a stronger statement helps minimize that issue. 

Further references to specific supporting files helps with the specifics they contain. Of particular importance is the architecture-reference.md for early planning. 

Even after all that Claude will sometimes sneak in some more if statements than wished for, and an odd try rescue might sneak in. So afterwards a run with Credo, Dialyzer and Sobelow is a good idea, and then I usually prompt to inform Claude that if statements and try rescue is often a code smell in Elixir and to review and use idiomatic flow construct instead. That tend to fix remaining issues. 





## Better results by adding this to the first project or refactor prompt:



**Do not use agents for planning or implementation. Do it yourself.**

**ALWAYS load the elixir skill and read both SKILL.md and architecture-reference.md before starting to plan architecture or writing any code. No exceptions, so do it right now!** The core skill contains essential rules, decision frameworks, and key patterns. Use architecture-reference.md to decide on layering, context boundaries, and process architecture. Then consult supporting files:

  - Use data-structures.md to choose the right data structure for each use case
  - Prefer ok/error tuples over exceptions, multi-clause functions
      over if/else, and pipelines over nested calls
  - Follow language-patterns.md for pattern matching, guards,
      with-chains, pipelines, comprehensions, and error handling
  - Read otp-reference.md when designing supervision trees,
    GenServers, or stateful processes
  - Use quick-references.md for Enum, Map, Keyword, List, String,
    and Stream operations — choose the right function, don't reinvent it
  - Follow documentation.md for @moduledoc, @doc, and doctests on
       all public functions
  - Follow code-style.md for module organization, function ordering,
      and formatter conventions
  - Follow type-system.md for @spec, @type, and the binary/String.t/iodata decision table
  - Use testing-reference.md and testing-examples.md for ExUnit,
    Mox, and async test patterns
  - Use ecto-reference.md for schemas, changesets, queries, and
    migrations
  - Every module must have @moduledoc, every public function must
    have @doc and @spec