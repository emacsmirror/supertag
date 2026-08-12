;;; ownership-separation-test.el --- Ownership phase safety tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: ./test/run-tests.sh ownership

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-core-scan)
(require 'supertag-services-sync)

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
            ;; Fully unowned legacy references are ambiguous and stay intact.
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
            (should-not (plist-get relation :kind))
            (should-not (plist-get relation :origin))
            (should (= 1 (plist-get counters :references-created)))
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
      (supertag-index-rebuild-relations)
      (setq field-reference
            (supertag-relation-create
             (list :type :reference
                   :from supertag-ownership-test-node-a
                   :to field-target
                   :kind :field-reference
                   :origin :field-value)))
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

(provide 'ownership-separation-test)

;;; ownership-separation-test.el ends here
