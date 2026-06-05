const std = @import("std");

pub const auto_wrap_shell_case =
    "git|rg|tree|find|docker|kubectl|gh|ps|ls|df|du|curl|make|cargo|zig|go|" ++
    "pytest|jest|vitest|tsc|eslint|biome|next|npm|pnpm|yarn|bun|cat|" ++
    "composer|gradle|gradlew|mvn|mvnw|pre-commit|terraform|tofu|aws|jq|" ++
    "psql|systemctl|lsof|brew";

pub const auto_wrap_js_array =
    "\"git\",\"rg\",\"tree\",\"find\",\"docker\",\"kubectl\",\"gh\",\"ps\",\"ls\",\"df\",\"du\"," ++
    "\"curl\",\"make\",\"cargo\",\"zig\",\"go\",\"pytest\",\"jest\",\"vitest\",\"tsc\"," ++
    "\"eslint\",\"biome\",\"next\",\"npm\",\"pnpm\",\"yarn\",\"bun\",\"cat\",\"composer\"," ++
    "\"gradle\",\"gradlew\",\"mvn\",\"mvnw\",\"pre-commit\",\"terraform\",\"tofu\",\"aws\"," ++
    "\"jq\",\"psql\",\"systemctl\",\"lsof\",\"brew\"";

pub const text =
    \\smll filters
    \\
    \\Agent auto-wrap commands:
    \\  git, rg, tree, find, docker, kubectl, gh, ps, ls, df, du, curl, make, cargo, zig, go,
    \\  pytest, jest, vitest, tsc, eslint, biome, next, npm, pnpm, yarn, bun, cat,
    \\  composer, gradle, gradlew, mvn, mvnw, pre-commit, terraform, tofu, aws, jq,
    \\  psql, systemctl, lsof, brew
    \\
    \\Dedicated filters:
    \\  git status/diff/log/show/add/commit/push/pull/fetch/merge/rebase/checkout/branch/stash/blame/reflog/grep
    \\  rg, tree, find, find -ls, cat, head, tail
    \\  docker ps/logs, kubectl get/logs, gh, ps, ls, df, systemctl, lsof, brew, psql
    \\  wc, env, du, curl -v/-vv/-vvv, aws JSON, jq JSON
    \\  make, cargo build/test, zig build, go build/test, dotnet build/test/format/restore
    \\  swift build, xcodebuild, gradle/gradlew, mvn/mvnw
    \\  pytest, jest, vitest, tsc, mypy, ruff, eslint, biome, prettier
    \\  npm/pnpm/yarn/bun/uv/uvx/pip/composer package output, bun pm ls
    \\  Vite/Next/Nuxt builds, next build, docker/kubectl logs, pre-commit
    \\  terraform plan, tofu plan
    \\  high-confidence generic table/list/text fallback
    \\
;

test "catalog names high-value filters" {
    try std.testing.expect(std.mem.find(u8, auto_wrap_shell_case, "terraform") != null);
    try std.testing.expect(std.mem.find(u8, auto_wrap_js_array, "\"aws\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "next build") != null);
    try std.testing.expect(std.mem.find(u8, text, "terraform plan") != null);
    try std.testing.expect(std.mem.find(u8, text, "eslint") != null);
    try std.testing.expect(std.mem.find(u8, text, "aws JSON") != null);
}
