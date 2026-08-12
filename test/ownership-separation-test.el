;;; ownership-separation-test.el --- Ownership phase safety tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: ./test/run-tests.sh ownership

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-automation)
(require 'supertag-automation-sync)
(require 'supertag-core-scan)
(require 'supertag-migration)
(require 'supertag-services-query)
(require 'supertag-services-sync)
(require 'supertag-view-kanban)
(require 'supertag-view-node)
(require 'supertag-view-table)

(ert-deftest supertag-ownership-test-fixture-is-repeatable-and-complete ()
  "The two-file fixture recreates the same files and every required fact."
  (supertag-ownership-test-with-vault
    (let ((first-files (mapcar (lambda (file)
                                 (with-temp-buffer
                                   (insert-file-contents-literally file)
                                   (buffer-string)))
                               files))
          (first-snapshot (supertag-ownership-test-semantic-snapshot)))
      (should (= 2 (length (directory-files vault nil "\\.org\\'"))))
      (should (string-match-p "#project" (car first-files)))
      (should (string-match-p "id:ownership-node-b" (car first-files)))
      (should (= 2 (hash-table-count (supertag-store-get-collection :nodes))))
      (should (member "project" (plist-get
                                  (supertag-store-get-entity
                                   :nodes supertag-ownership-test-node-a)
                                  :tags)))
      (should (supertag-store-get-field-definition "status"))
      (should (equal '((:field-id "status" :order 0))
                     (supertag-store-get-tag-field-associations "project")))
      (should (equal "active"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (should (eq :document-link
                  (plist-get (supertag-store-get-entity
                              :relations supertag-ownership-test-document-link)
                             :kind)))
      (should (eq :semantic-edge
                  (plist-get (supertag-store-get-entity
                              :relations supertag-ownership-test-semantic-edge)
                             :kind)))
      (should (supertag-store-get-entity :boards "ownership-board"))
      (should (supertag-store-get-entity :automations "ownership-automation"))
      (should (assoc "active-projects" supertag-query-saved))
      (should (equal files (supertag-ownership-test-create-vault vault)))
      (supertag-ownership-test-populate-store files)
      (should (equal first-files
                     (mapcar (lambda (file)
                               (with-temp-buffer
                                 (insert-file-contents-literally file)
                                 (buffer-string)))
                             files)))
      (should (equal first-snapshot
                     (supertag-ownership-test-semantic-snapshot))))))

(ert-deftest supertag-ownership-test-fingerprint-covers-every-semantic-source ()
  "Changing or losing any Semantic Fact source changes its fingerprint."
  (supertag-ownership-test-with-vault
    (dolist (collection supertag-ownership-test-semantic-collections)
      (supertag-ownership-test-populate-store files)
      (let ((before (supertag-ownership-test-semantic-fingerprint)))
        (puthash "fingerprint-change" '(:id "fingerprint-change")
                 (supertag-store-get-collection collection))
        (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))
      (supertag-ownership-test-populate-store files)
      (let ((before (supertag-ownership-test-semantic-fingerprint)))
        (remhash collection supertag--store)
        (should-not (equal before (supertag-ownership-test-semantic-fingerprint)))))
    (supertag-ownership-test-populate-store files)
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (remhash supertag-ownership-test-semantic-edge
               (supertag-store-get-collection :relations))
      (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))
    (supertag-ownership-test-populate-store files)
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (setq supertag-query-saved nil)
      (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-ownership-test-fingerprint-excludes-document-projection ()
  "A Document Projection change alone does not change Semantic Facts."
  (supertag-ownership-test-with-vault
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put (copy-sequence
                   (supertag-store-get-entity :nodes supertag-ownership-test-node-a))
                  :title "Project Alpha rescanned"))
      (supertag-store-remove-entity
       :relations supertag-ownership-test-document-link)
      (should (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-reindex-keeps-unknown-tag-occurrence-out-of-semantic-store ()
  "Reindex records unknown Org tokens without creating Semantic Tags."
  (supertag-ownership-test-with-vault
    (let* ((file (cadr files))
           (before (supertag-ownership-test-semantic-fingerprint))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (counters (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                           :references-created 0 :references-deleted 0)))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (end-of-line)
        (insert " #emerging")
        (write-region nil nil file nil 'silent))
      (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                 (lambda () t)))
        (supertag-sync--process-single-file file counters))
      (let ((node (supertag-node-get supertag-ownership-test-node-b)))
        (should (equal '("reference" "emerging")
                       (plist-get node :tag-occurrences)))
        (should (equal '("reference") (plist-get node :tags)))
        (should (equal '("emerging") (plist-get node :unresolved-tags))))
      (should-not (supertag-tag-get "emerging"))
      (should-not
       (supertag-relation-find-between
        supertag-ownership-test-node-b "emerging" :node-tag))
      (should (equal (list supertag-ownership-test-node-b)
                     (supertag-index-get-nodes-by-tag "emerging")))
      (should (equal (list supertag-ownership-test-node-b)
                     (supertag-query-sexp '(tag "emerging"))))
      (should (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-reindex-projects-document-links-without-writing-org ()
  "Reindex projects Org links without inserting reciprocal file links."
  (supertag-ownership-test-with-vault
    (let* ((project-file (car files))
           (reference-file (cadr files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--is-full-rescan-p t)
           (counters (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                           :references-created 0 :references-deleted 0))
           (target-buffer (find-file-noselect reference-file))
           before relation)
      (supertag-index-rebuild-relations)
      (supertag-relation-delete supertag-ownership-test-document-link)
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put (copy-sequence
                   (supertag-node-get supertag-ownership-test-node-a))
                  :hash "stale"))
      (setq before
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (secure-hash 'sha256 (current-buffer))))
                    files))
      (unwind-protect
          (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                     (lambda () t))
                    ((symbol-function 'supertag-ui--find-node-marker)
                     (lambda (_node-id)
                       (with-current-buffer target-buffer
                         (copy-marker (point-min)))))
                    ((symbol-function 'supertag-ui--file-node-p)
                     (lambda (_node-id) nil)))
            (supertag-sync--process-single-file project-file counters)
            (should
             (equal before
                    (mapcar (lambda (file)
                              (with-temp-buffer
                                (insert-file-contents-literally file)
                                (secure-hash 'sha256 (current-buffer))))
                            files)))
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should relation)
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 1 (length (supertag-relation-find-by-from
                                  supertag-ownership-test-node-a :reference))))
            (should (= 1 (length (supertag-relation-find-by-to
                                  supertag-ownership-test-node-b :reference))))
            (should (= 1 (plist-get counters :references-created)))
            ;; A partially classified projection is completed in place.
            (supertag-store-put-entity
             :relations (plist-get relation :id)
             (plist-put (plist-put (copy-sequence relation)
                                   :kind :document-link)
                        :origin nil))
            (supertag-store-put-entity
             :nodes supertag-ownership-test-node-a
             (plist-put (copy-sequence
                         (supertag-node-get supertag-ownership-test-node-a))
                        :hash "stale"))
            (supertag-sync--process-single-file project-file counters)
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 1 (plist-get counters :references-created)))
            ;; The authoritative Org occurrence classifies an unowned legacy
            ;; reference as a Document Link during reconciliation.
            (supertag-store-put-entity
             :relations (plist-get relation :id)
             (plist-put (plist-put (copy-sequence relation) :kind nil)
                        :origin nil))
            (supertag-store-put-entity
             :nodes supertag-ownership-test-node-a
             (plist-put (copy-sequence
                         (supertag-node-get supertag-ownership-test-node-a))
                        :hash "stale"))
            (supertag-sync--process-single-file project-file counters)
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 2 (plist-get counters :references-created)))
            (should
             (equal before
                    (mapcar (lambda (file)
                              (with-temp-buffer
                                (insert-file-contents-literally file)
                                (secure-hash 'sha256 (current-buffer))))
                            files))))
        (kill-buffer target-buffer)))))

(ert-deftest supertag-document-link-cleanup-preserves-field-references ()
  "Removing an Org link does not delete a database-owned field reference."
  (supertag-ownership-test-with-vault
    (let* ((field-target "ownership-field-target")
           (counters '(:references-created 0 :references-deleted 0))
           field-reference)
      (supertag-store-put-entity
       :nodes field-target
       (list :id field-target :type :node :title "Field Target"))
      (supertag-store-put-field-definition
       "refs" '(:id "refs" :name "Refs" :type :node-reference))
      (supertag-store-put-field-value
       supertag-ownership-test-node-a "refs" field-target)
      (supertag-index-rebuild-relations)
      (setq field-reference
            (supertag-relation-create
             (list :type :reference
                   :from supertag-ownership-test-node-a
                   :to field-target
                   :kind :field-reference
                   :origin :field-value
                   :field-id "refs")))
      (supertag--cleanup-orphaned-references
       supertag-ownership-test-node-a nil counters)
      (should-not
       (supertag-relation-get supertag-ownership-test-document-link))
      (should (supertag-relation-get (plist-get field-reference :id)))
      (should (= 1 (plist-get counters :references-deleted))))))

(ert-deftest supertag-reindex-org-cold-rebuilds-document-projection ()
  "The public reindex command rebuilds projections, not Semantic Facts."
  (supertag-ownership-test-with-vault
    (let* ((before-semantic (supertag-ownership-test-semantic-fingerprint))
           (before-files
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (secure-hash 'sha256 (current-buffer))))
                    files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           projection-relation-ids report)
      (maphash
       (lambda (id relation)
         (when (or (eq (plist-get relation :type) :node-tag)
                   (supertag-relation-document-link-p relation))
           (push id projection-relation-ids)))
       (supertag-store-get-collection :relations))
      (dolist (id projection-relation-ids)
        (supertag-store-remove-entity :relations id))
      (clrhash (supertag-store-get-collection :nodes))
      (supertag-index-rebuild-relations)
      (cl-letf (((symbol-function 'supertag-sync--ensure-state-source) #'ignore)
                ((symbol-function 'supertag-sync--snapshot-build)
                 (lambda ()
                   (list :status 'complete :files files :scope (list vault)
                         :errors nil :observed-at (current-time))))
                ((symbol-function 'supertag-scan-sync-directories)
                 (lambda (&rest _)
                   (ert-fail "reindex rescanned past its authoritative snapshot")))
                ((symbol-function 'supertag-sync-save-state) #'ignore))
        (setq report (supertag-reindex-org)))
      (should (eq 'complete (plist-get report :status)))
      (should (eq 'complete (plist-get report :snapshot-status)))
      (should (= 2 (plist-get report :files-discovered)))
      (should (= 2 (plist-get report :files-processed)))
      (should (= 2 (hash-table-count
                    (supertag-store-get-collection :nodes))))
      (let ((document-link
             (car (supertag-relation-find-between
                   supertag-ownership-test-node-a
                   supertag-ownership-test-node-b :reference))))
        (should (supertag-relation-document-link-p document-link)))
      (should (equal (list supertag-ownership-test-node-b)
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-a)
                      :ref-to)))
      (should (equal (list supertag-ownership-test-node-a)
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-b)
                      :ref-from)))
      (should (= 1 (plist-get
                    (supertag-node-get supertag-ownership-test-node-b)
                    :ref-count)))
      (should (supertag-relation-get
               supertag-ownership-test-semantic-edge))
      (should (equal before-semantic
                     (supertag-ownership-test-semantic-fingerprint)))
      (should
       (equal before-files
              (mapcar (lambda (file)
                        (with-temp-buffer
                          (insert-file-contents-literally file)
                          (secure-hash 'sha256 (current-buffer))))
                      files))))))

(ert-deftest supertag-global-field-audit-is-repeatable-and-read-only ()
  "A complete legacy/global mapping is deterministic and never mutates Store."
  (supertag-ownership-test-with-vault
    (let* ((legacy-definition
            '(:name "Status" :type :enum
              :options ("active" "done") :default "active"))
           (project (copy-tree (supertag-store-get-entity :tags "project")))
           (reference (copy-tree (supertag-store-get-entity :tags "reference")))
           report first-store database-sha)
      (supertag-store-put-entity
       :tags "project" (plist-put project :fields (list legacy-definition)))
      (supertag-store-put-entity
       :tags "reference" (plist-put reference :extends "project"))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "active")
      ;; Legacy values are stored under the node's selected tag even when the
      ;; field itself is inherited from that tag's parent.
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-b "reference" "Status" "done")
      (make-directory (file-name-directory supertag-db-file) t)
      (with-temp-file supertag-db-file (insert "audit-must-not-write\n"))
      (setq first-store
            (supertag--persistence--canonicalize-value supertag--store)
            database-sha (with-temp-buffer
                           (insert-file-contents-literally supertag-db-file)
                           (secure-hash 'sha256 (current-buffer)))
            report (supertag-migration-audit-global-fields))
      ;; Reinsert every audited collection in reverse key order.  The report
      ;; must describe facts, not hash-table insertion order.
      (dolist (collection supertag-migration--global-field-backup-collections)
        (let ((replacement (make-hash-table :test 'equal)))
          (dolist (entry
                   (reverse
                    (supertag-migration--sorted-table-entries
                     (supertag-store-get-collection collection))))
            (puthash (car entry) (cdr entry) replacement))
          (puthash collection replacement supertag--store)))
      (should (equal report (supertag-migration-audit-global-fields)))
      (should (equal first-store
                     (supertag--persistence--canonicalize-value supertag--store)))
      (should (equal database-sha
                     (with-temp-buffer
                       (insert-file-contents-literally supertag-db-file)
                       (secure-hash 'sha256 (current-buffer)))))
      (should (plist-get report :safe-to-apply))
      (should-not (plist-get report :conflicts))
      (should-not (plist-get report :orphans))
      (should (equal :equal
                     (plist-get (car (plist-get report :definition-mappings))
                                :status)))
      (should (equal :equal
                     (plist-get (car (plist-get report :association-mappings))
                                :status)))
      (should (equal '(:equal :would-create)
                     (mapcar (lambda (item) (plist-get item :status))
                             (plist-get report :value-parity))))
      (should (= 2 (plist-get (plist-get report :coverage)
                              :legacy-values)))
      (should (eq :full-database
                  (plist-get (plist-get report :backup) :scope)))
      (should (equal supertag--store-collections
                     (plist-get (plist-get report :backup) :collections)))
      (should (stringp
               (plist-get (plist-get report :backup) :store-sha256))))))

(ert-deftest supertag-global-field-audit-conflicts-fail-closed ()
  "Definition/value mismatches block the existing force-write entry point."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields t)
           (project (copy-tree (supertag-store-get-entity :tags "project")))
           (reference (copy-tree (supertag-store-get-entity :tags "reference")))
           report before reasons)
      (supertag-store-put-entity
       :tags "project"
       (plist-put project :fields '((:name "Status" :type :string)
                                    (:name "Priority" :type :string))))
      (supertag-store-put-entity
       :tags "reference"
       (plist-put reference :fields '((:name " priority "))))
      ;; A malformed target must become a report conflict, not abort audit.
      (puthash "status" :malformed
               (supertag-store-get-collection :field-definitions))
      ;; Matching IDs are not enough to overwrite extra association semantics.
      (supertag-store-put-tag-field-associations
       "project" '((:field-id "status" :order 0 :required t)))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "legacy")
      (setq report (supertag-migration-audit-global-fields)
            before (supertag--persistence--canonicalize-value supertag--store)
            reasons (mapcar (lambda (item) (plist-get item :reason))
                            (plist-get report :conflicts)))
      (should-not (plist-get report :safe-to-apply))
      (should (memq :definition-target-mismatch reasons))
      (should (memq :invalid-field-definition reasons))
      (should (memq :display-name-collision reasons))
      (should (memq :association-target-mismatch reasons))
      (should (memq :global-value-mismatch reasons))
      (should-error (supertag-migration-run-global-fields t)
                    :type 'user-error)
      (should (equal before
                     (supertag--persistence--canonicalize-value supertag--store))))))

(ert-deftest supertag-global-field-audit-allows-clean-existing-migration ()
  "The audit gate preserves the existing conflict-free apply path."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields t)
           (project (copy-tree (supertag-store-get-entity :tags "project"))))
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags "project"
       (plist-put project :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "ready")
      (should (plist-get (supertag-migration-audit-global-fields)
                         :safe-to-apply))
      (supertag-migration-run-global-fields t)
      (should (eq :string
                  (plist-get (supertag-store-get-field-definition "status")
                             :type)))
      (should (equal '((:field-id "status" :order 0))
                     (supertag-store-get-tag-field-associations "project")))
      (should (equal "ready"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status"))))))

(ert-deftest supertag-global-field-audit-reports-orphans ()
  "Legacy and global values without owners are reported and block migration."
  (supertag-ownership-test-with-vault
    (let ((reference
           (copy-tree (supertag-store-get-entity :tags "reference"))))
      (supertag-store-put-entity
       :tags "reference"
       (plist-put reference :fields '((:name "Ghost" :type :string))))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "reference" "Ghost" "stale")
      (supertag-store-put-legacy-field
       "missing-node" "missing-tag" "Ghost" "legacy")
      (supertag-store-put-field-value "missing-node" "missing-field" "global")
      (supertag-store-put-tag-field-associations
       "missing-tag" '((:field-id "missing-field" :order 0))))
    (let* ((report (supertag-migration-audit-global-fields))
           (orphans (plist-get report :orphans))
           (kinds (mapcar (lambda (item) (plist-get item :kind)) orphans))
           (reasons (apply #'append
                           (mapcar (lambda (item) (plist-get item :reasons))
                                   orphans))))
      (should-not (plist-get report :safe-to-apply))
      (should (memq :legacy-value kinds))
      (should (memq :global-value kinds))
      (should (memq :global-association kinds))
      (should (memq :missing-node reasons))
      (should (memq :missing-tag reasons))
      (should (memq :tag-not-on-node reasons))
      (should (memq :undeclared-field reasons))
      (should (memq :missing-field-definition reasons)))))

(ert-deftest supertag-global-fields-are-the-only-production-write-path ()
  "Legacy configuration cannot make production field APIs write legacy data."
  (supertag-ownership-test-with-vault
    ;; Existing user configs may still set this obsolete option to nil.  The
    ;; cutover must ignore it instead of reopening the legacy writer.
    (let ((supertag-use-global-fields nil))
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-tag-add-field
       "project" '(:name "Status" :type :string))
      (supertag-tag-add-field
       "project" '(:name "Priority" :type :integer))
      (supertag-field-set
       supertag-ownership-test-node-a "project" "Status" "active")
      (supertag-field-set-many
       supertag-ownership-test-node-a
       '((:tag "project" :field "Status" :value "done")
         (:tag "project" :field "Priority" :value 2)))
      (supertag-tag-move-field-up "project" "priority")
      (should (equal '("priority" "status")
                     (mapcar #'supertag--assoc-entry-field-id
                             (supertag-store-get-tag-field-associations
                              "project"))))
      (should (= 2 (supertag-field-remove
                    supertag-ownership-test-node-a
                    "project" "Priority")))
      (supertag-tag-remove-field "project" "Priority")
      (should (supertag-store-get-field-definition "status"))
      (should (supertag-store-get-field-definition "priority"))
      (should (equal '("status")
                     (mapcar #'supertag--assoc-entry-field-id
                             (supertag-store-get-tag-field-associations
                              "project"))))
      (should (equal "done"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (supertag-tag-rename-field "project" "Status" "State")
      (should (equal "done"
                     (supertag-field-get
                      supertag-ownership-test-node-a "project" "State")))
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query--find-nodes-by-field-indexed
                      "State" "done")))
      (should (member "status"
                      (supertag--extract-trigger-sources
                       '(field-changed "State"))))
      (should
       (eq :unknown
           (supertag-automation--event-type
            (list :path
                  (list :fields supertag-ownership-test-node-a
                        "project" "Status")))))
      (should-not
       (supertag-automation--trigger-match-p
        :on-field-change
        (list :path
              (list :fields supertag-ownership-test-node-a
                    "project" "Status"))))
      (let ((supertag-automation--current-event
             (list :path
                   (list :field-values
                         supertag-ownership-test-node-a "status"))))
        (should
         (supertag-automation--eval-single-condition
          '(field-changed "State")
          (supertag-store-get-entity
           :nodes supertag-ownership-test-node-a))))
      (supertag-automation-sync--update-node-field
       supertag-ownership-test-node-a "State" "synced")
      (should (equal "synced"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (should (eq :missing
                  (supertag-store-get-field-value
                   supertag-ownership-test-node-a "state" :missing)))
      (should (eq :missing
                  (supertag-store-get-field-value
                   supertag-ownership-test-node-a "priority" :missing)))
      (should-not (plist-get (supertag-store-get-entity :tags "project")
                             :fields))
      (should (zerop (hash-table-count
                      (supertag-store-get-collection :fields)))))))

(ert-deftest supertag-global-field-cutover-preserves-consumer-parity ()
  "Migration preserves Table/Node/Kanban/Automation output without legacy reads."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields nil)
           (node-id supertag-ownership-test-node-a)
           (tag-id "project")
           (node (supertag-store-get-entity :nodes node-id))
           backup-files
           legacy-snapshot)
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags tag-id
       (plist-put (copy-tree (supertag-store-get-entity :tags tag-id))
                  :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field node-id tag-id "Status" "active")
      (setq legacy-snapshot
            (supertag--persistence--canonicalize-value
             (list :definitions
                   (plist-get (supertag-store-get-entity :tags tag-id) :fields)
                   :values (supertag-store-get-collection :fields))))
      (supertag-migration-run-global-fields t)
      (setq backup-files
            (directory-files
             supertag-db-backup-directory t
             "\\`supertag-db-preglobal-fields-.*\\.el\\'"))
      (should (= 1 (length backup-files)))
      (let* ((backup-store
              (supertag--persistence--try-read-store
               (car backup-files)))
             (backup-tag
              (gethash tag-id (gethash :tags backup-store))))
        (should
         (equal legacy-snapshot
                (supertag--persistence--canonicalize-value
                 (list :definitions (plist-get backup-tag :fields)
                       :values (gethash :fields backup-store))))))
      (supertag-ops-schema-rebuild-cache)
      (cl-labels
          ((consumer-snapshot ()
             (let* ((column '(:name "Status" :key status
                              :field-id "status" :type :string))
                    (grouped
                     (supertag-view-kanban--group-nodes-by-field
                      (list (cons node-id node)) tag-id "Status")))
               (list
                (cl-letf (((symbol-function
                            'supertag-view-table--get-current-query-obj)
                           (lambda () '(:type :tag)))
                          ((symbol-function
                            'supertag-view-table--get-current-tag-id)
                           (lambda () tag-id)))
                  (substring-no-properties
                   (supertag-view-table--get-cell-value
                    node 'status column)))
                (supertag-view-node--count-fields node-id)
                (length (gethash "active" grouped))
                (supertag-automation--get-field-value
                 node-id (list tag-id) "Status")))))
        (should (equal '("active" 1 1 "active")
                       (consumer-snapshot)))
        (supertag-field-set node-id tag-id "Status" "done")
        (should (equal '("done" 1 0 "done")
                       (consumer-snapshot))))
      (should
       (equal legacy-snapshot
              (supertag--persistence--canonicalize-value
               (list :definitions
                     (plist-get (supertag-store-get-entity :tags tag-id)
                                :fields)
                     :values (supertag-store-get-collection :fields))))))))

(ert-deftest supertag-global-field-cutover-rolls-back-on-error ()
  "A failed cutover restores global collections and retains its backup."
  (supertag-ownership-test-with-vault
    (let* ((node-id supertag-ownership-test-node-a)
           (tag-id "project")
           before
           backup-files)
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags tag-id
       (plist-put (copy-tree (supertag-store-get-entity :tags tag-id))
                  :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field node-id tag-id "Status" "active")
      (setq before
            (supertag--persistence--canonicalize-value
             (list (supertag-store-get-collection :field-definitions)
                   (supertag-store-get-collection :tag-field-associations)
                   (supertag-store-get-collection :field-values))))
      (cl-letf (((symbol-function
                  'supertag-migration--migrate-field-values)
                 (lambda (&rest _)
                   (error "forced cutover failure"))))
        (should-error (supertag-migration-run-global-fields t)
                      :type 'error))
      (should
       (equal before
              (supertag--persistence--canonicalize-value
               (list (supertag-store-get-collection :field-definitions)
                     (supertag-store-get-collection
                      :tag-field-associations)
                     (supertag-store-get-collection :field-values)))))
      (setq backup-files
            (directory-files
             supertag-db-backup-directory t
             "\\`supertag-db-preglobal-fields-.*\\.el\\'"))
      (should (= 1 (length backup-files)))
      (let ((backup-store
             (supertag--persistence--try-read-store
              (car backup-files))))
        (dolist (collection '(:field-definitions
                              :tag-field-associations
                              :field-values))
          (let ((table (gethash collection backup-store)))
            (should (zerop (if (hash-table-p table)
                               (hash-table-count table)
                             0)))))
        (should
         (equal "active"
                (gethash "Status"
                         (gethash tag-id
                                  (gethash node-id
                                           (gethash :fields backup-store))))))))))

(provide 'ownership-separation-test)

;;; ownership-separation-test.el ends here
