# change_query_syntax_alignment_20260813

## 2026-08-13 — task001 (task ...) 与 (priority ...) 操作符

- Modify `supertag-services-query.el`：parser 新增 `task`/`priority` 分支（零或
  多参数，零参数 = 无匹配）；executor 新增对应 AST 分支：`task` 大小写敏感
  匹配 node `:todo`、`priority` 大小写不敏感匹配 node `:priority`，均 O(N)
  扫描投影节点。
- Modify `doc/QUERY.md`：语法表新增两行。
- Modify `test/query-block-test.el`：新增 2 项定向 ERT（单/多参数、大小写、
  无状态节点、零参数、与 not 组合）。

Verification：`./test/run-tests.sh query` 31/31；修改文件 byte-compile 零新增
warning；`git diff --check` 通过。全量回归见 task009 验收。
