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

(provide 'ownership-separation-test)

;;; ownership-separation-test.el ends here
