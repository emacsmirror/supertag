# change_ownership_separation_20260812

## 2026-08-12 — task004 Transactional node delete cleanup

- Modify `supertag-ops-node.el`：删除 node 时不再直接扫描/remhash relations；统一调用 `supertag-relation-delete-for-node`，并在删除 node 前清理 legacy `:fields` 与 global `:field-values` per-node bucket；整个操作进入 `supertag-with-transaction`。
- Modify `supertag-core-transform.el`：transaction rollback 对 `:fields` / `:field-values` 的 per-node nested hash table 使用同一个 direct restore 分支，避免 canonical entity normalization 把 hash table 压成 plist。
- Modify `supertag-ops-relation.el`：transaction rollback 后复用 `supertag-index-rebuild-relations` 恢复 from/to derived indexes。
- Modify `test/node-ops-test.el`：覆盖 incoming/outgoing relations、两类 field store、from/to indexes 的成功清理，以及后置 hook 失败后的完整 rollback。
- Add `issue039`：记录旧删除路径的数据残留、根因、修复和真实 Vault 确认项。

Behavior：公开命令和返回值不变；成功删除不再遗留 field bucket、relation 或 index entry。失败删除恢复 node、surviving peer ref cache、relations、fields 与 indexes。

Risk：失败事务会执行一次 O(R) relation index rebuild；成功路径仍使用既有增量 index operations。未改变 Org headline 删除或 reciprocal link 文件行为。

Verification：新增两条 ERT 先红后绿；`./test/run-tests.sh node tx field-ref` 39/39 通过；修改文件 byte-compile 仅有既有 obsolete/docstring/forward declaration warning；`git diff --check` 通过；提交态临时 clone 全量 ERT 422/422 通过。

## 2026-08-12 — task003 Durable root contract 与完整保存验证

- Modify `supertag-core-store.el`：将 `:automations`、`:sync-conflicts` 纳入唯一 Store root contract；补齐 entity-plist collection 声明，并移除代码注释中的 Store 全局单一真相源表述。
- Modify `supertag-core-persistence.el`：保存后不再只比较 node count，而是按 `supertag--store-collections` 对每个 entity ID 的 canonical value 做 O(N) 内容比较；任一 durable collection 丢失、增删或同数量内容变化都会在替换旧数据库前中止。
- Modify root normalization：兼容 `boards`、`automations`、`sync-conflicts` 的非 keyword legacy root 名称。
- Modify persistence/canonical/conflict tests：复用 task002 fixture，覆盖正式 root 声明、所有已填充 durable roots 丢失、同数量内容变化、完整 round-trip、原数据库保留，以及 fresh Store 中空 `:sync-conflicts` contract。

Behavior：数据库文件格式不变；成功保存仍走原 canonical writer。验证失败现在会列出发生变化的 durable collections，并继续保留旧数据库文件。

Risk：启用默认 save verification 时增加一次 O(N) 内容比较；实现逐 entity 比较且不排序 whole collection，避免再构造一份完整 Store snapshot。空 collection 与 canonical 文件中的缺席等价。

Verification：`./test/run-tests.sh persist canon` 51/51、`./test/run-tests.sh ownership` 3/3、`./test/run-tests.sh conflicts` 25/25 通过；修改文件 byte-compile 仅有既有 docstring/obsolete warning，本 task 新函数无 warning；`git diff --check` 通过；提交态临时 clone 全量 ERT 420/420 通过。

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
