# change_supertag_rename_20260819

## 2026-08-19 — task001 锁定破坏性改名规格与仓库基线

- Modify `.phrase/docs/pr_faq_supertag_breaking_rename_20260819.md`：用户批准，
  状态更新为 Approved。
- Add phase spec/plan/task/ADR/change：锁定唯一 `supertag` 命名、零兼容层、
  人工数据目录迁移、旧目录失败保护与 GitHub 最后改名顺序。
- Baseline：`git grep` 得到 191 个 tracked 文件、1032 个旧名匹配行；历史
  `.phrase` phase 文档保留原始事实，当前 runtime/docs/tests 进入迁移范围。

Verification：PR/FAQ FAQ 编号 1-13 连续；phase 文档互相一致；
`git diff --check` 通过。

## 2026-08-19 — task002 运行时破坏性切换

- Rename `org-supertag.el` → `supertag.el`：包版本更新为 6.0.0，唯一 feature
  为 `supertag`；所有现存配置、vault、search mode 与 warning group 改为
  `supertag-*`。
- Delete `supertag-compat.el`；Delete interactive search、view style 与旧 Babel
  execute alias，不提供运行时兼容入口。
- Modify `supertag-ui-query-block.el`：唯一 Babel 语言与执行函数改为
  `supertag-query-block` / `org-babel-execute:supertag-query-block`。
- Modify `supertag-core-persistence.el`：默认数据与本机锁目录改为 `supertag`；
  新增旧默认目录检查，只报错，不移动或删除数据。
- Modify sync/setup/git/search/query/tests：公开变量、`require`、library 定位和
  测试调用统一改名。
- Add persistence ERT：旧目录单独存在、双目录冲突、自定义目录三条路径。

Verification：`./test/run-tests.sh persist query git` 117/117；隔离
`user-emacs-directory` 的 `(require 'supertag)` 成功，且
`(locate-library "org-supertag")` 返回 nil；`git diff --check` 通过。
