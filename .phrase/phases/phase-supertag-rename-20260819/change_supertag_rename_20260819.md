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
