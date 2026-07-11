# CodexPlusPlus-on-Linux Agent Rules

This file records repository-local rules for AI agents working on this project.

## Prompt Draft Privacy Rule

Do not read `.ai_prompts_draft/` by default.

That directory is a maintainer scratch area for conversation prompt drafts and may contain obsolete, invalid, or misleading text.
An agent may read from it only when the maintainer explicitly asks for a specific file or explicitly grants permission to inspect prompt drafts in the current task.

If permission is granted for one file, read only that file unless the maintainer broadens the scope.

## Maintenance Workflow Rule

The official maintenance workflow is documented in `docs/modules/ROOT/pages/maintenance-workflow.adoc` and `docs/modules/ROOT/pages/maintenance-workflow_zh-CN.adoc`.
Treat the older full-automation workflow as experimental or historical unless the maintainer explicitly re-enables it.
