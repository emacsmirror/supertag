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

## 2026-08-13 — task002 not 多参数

- Modify `supertag-services-query.el`：parser 的 `not` 从"恰好一个"放宽为
  "至少一个"（零参数仍报错），AST 节点 `:child` 改为 `:children`；executor
  改为排除全部子条件的并集（等价 `(not (or ...))`）；`--get-fields-from-ast`
  的 not 遍历同步适配。
- Modify `doc/QUERY.md`：not 行更新。
- Modify `test/query-block-test.el`：新增定向 ERT（多参数、单参数不变、
  零参数报错、与 task/priority 嵌套）。

Verification：`./test/run-tests.sh query` 32/32；`git diff --check` 通过。
