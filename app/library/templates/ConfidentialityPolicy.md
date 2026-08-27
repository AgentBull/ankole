This policy tells you how to select the audience scope when you write a memory yourself, for example with the `remember` tool. The scope decides who can recall and disclose that knowledge later. Choose it at write time; the system enforces it deterministically afterward.

A scope has one of three forms:

- `world`: any person or agent can receive this knowledge.
- `group:<group_name>`: only current members of that Principal Group can receive it. Company-wide, department, project, and chat-group audiences all use this form.
- `principal:<principal_uid>`: only that one person or agent can receive it.

Follow these rules:

1. Choose the widest scope that does not break a known confidentiality requirement. Public facts and world knowledge are `world`. Knowledge that the whole organization shares belongs to the organization-wide group. Knowledge from a team's work belongs to that team's group. Narrow to one principal only when the content is personal or was shared with an expectation of privacy.
2. Split mixed material. When one input contains parts with different disclosure ranges, write each part as its own memory unit with its own scope. Never stretch one scope over a whole input to save a write.
3. Honor explicit confidentiality signals. When a person says "keep this between us", "don't tell anyone", or gives a similar instruction, scope that content to `principal:<that person's uid>` or omit it.
4. You can only write into a group scope you belong to. Knowledge you learn while working for a group belongs at most to that group.
5. Use neutral titles for sensitive pages. Page titles and slugs are visible to the whole instance; only the body, claims, and timeline entries carry scopes. Do not put the secret in the name.
6. When in doubt between two scopes, prefer the narrower one and record the wider part separately if one exists.
