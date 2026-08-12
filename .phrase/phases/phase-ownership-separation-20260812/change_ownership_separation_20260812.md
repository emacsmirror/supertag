# change_ownership_separation_20260812

## 2026-08-12 — task001 Ownership Constitution 与迁移地图

- Add `CONTEXT.md`：固定 Document Fact、Semantic Fact、Projection、Tag Occurrence、Semantic Tag、Document Link、Semantic Edge、Backlink、Reindex 与 Semantic Restore 术语。
- Add `doc/OWNERSHIP-CONSTITUTION_cn.md`：规定一个事实一个 Owner、写入方向、Reindex/Semantic Restore 区别及迁移约束。
- Add phase `spec` / `plan` / `tech-refer` / `ADR` / `task`：记录当前代码地图、目标 Module Interface、28 个原子任务和依赖顺序。
- Modify `README.md`, `README_CN.md`：不再把 `supertag-sync-full-rescan` 描述为 whole-database rebuild。
- Modify `doc/ONTOLOGY-ARCHITECTURE_cn.md`：将 Store 修正为当前物理容器，并加入所有权轴和目标读写流。
- Modify plugin guides：raw Store collection 降为 legacy compatibility Interface，禁止新增 caller。

Behavior：仅文档变化；runtime、数据库和用户 Org 文件均不变。

Risk：文档描述的是分阶段迁移目标；当前 mixed Store 与 legacy raw read 仍存在，后续 task 不得把目标状态误当作已完成状态。

Verification：`git diff --check`；Ownership 文档链接存在；旧的正向 “Store is the single source of truth” 与 “full rescan rebuilds the database” 表述已移除。
