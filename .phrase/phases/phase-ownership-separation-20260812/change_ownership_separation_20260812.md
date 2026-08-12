# change_ownership_separation_20260812

## 2026-08-12 — task002 两文件 Vault fixture 与 Semantic Fact fingerprint

- Add `test/ownership-fixture.el`：动态创建两个确定性 Org 文件，并建立覆盖 node、Tag Occurrence、schema、field value、Document Link、Semantic Edge、Board、Automation 与 saved query 的隔离 Store。
- Add `supertag-ownership-test-semantic-snapshot` / `supertag-ownership-test-semantic-fingerprint`：复用 canonical serializer，只捕获 Semantic Facts，明确排除 Document nodes 与 Document Links。
- Add `test/ownership-separation-test.el`：验证 fixture 可重复创建、每个 semantic collection 的修改/丢失都会改变 fingerprint、Document Projection 变化不会误报。
- Modify `test/run-tests.sh`：将 ownership tests 加入稳定测试集，并提供 `ownership` filter。

Behavior：仅增加测试基础设施；runtime、数据库和用户 Org 文件不变。

Verification：`./test/run-tests.sh ownership` 3/3 通过；两个新增 Elisp 文件 byte-compile 无 warning；`git diff --check` 通过；从提交态创建的临时本地 clone 中运行 `./test/run-tests.sh all`，416/416 通过。当前工作树中用户未提交的 Dashboard/TextUI 实验未进入验证提交或本 task。

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
