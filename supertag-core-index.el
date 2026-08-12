;;; supertag-core-index.el --- Rebuildable Store indexes -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the cold-rebuild lifecycle for every Store-derived runtime index.
;; Relation indexes are maintained incrementally; Tag/schema/rule modules keep
;; their own data structures but are cleared and rebuilt through the single
;; `supertag-index-clear-all'/`supertag-index-rebuild-all' boundary.

;;; Code:

(require 'cl-lib)

(defvar supertag--store)

;;; --- Index Variables ---

(defvar supertag--index-relations-by-from (make-hash-table :test 'equal)
  "Index: from-id -> hash-table of relation-id -> t.")

(defvar supertag--index-relations-by-to (make-hash-table :test 'equal)
  "Index: to-id -> hash-table of relation-id -> t.")

(defvar supertag--index-relations-source-token nil
  "Source token represented by the current relation indexes.")

(defvar supertag--index-nodes-by-tag (make-hash-table :test 'equal)
  "Index: Tag ID or occurrence token -> hash-set of node IDs.")

(defvar supertag--index-node-ranks (make-hash-table :test 'equal)
  "Index: node ID -> Store traversal rank for query-order compatibility.")

(defvar supertag--index-nodes-source-token nil
  "Source token represented by `supertag--index-nodes-by-tag'.")

(defvar supertag--index-source-revisions (make-hash-table :test 'eq)
  "Monotonic in-memory revisions for Store collections.")

(defun supertag-index-note-store-change (collection)
  "Record a mutation of Store COLLECTION."
  (puthash collection
           (1+ (gethash collection supertag--index-source-revisions 0))
           supertag--index-source-revisions))

(defun supertag-index-source-token (collections)
  "Return the current Store identity and revisions for COLLECTIONS."
  (cons supertag--store
        (mapcar (lambda (collection)
                  (cons collection
                        (gethash collection supertag--index-source-revisions 0)))
                collections)))

(defun supertag-index-source-current-p (token collections)
  "Return non-nil when TOKEN still represents COLLECTIONS in the live Store."
  (and token
       (eq (car token) supertag--store)
       (equal (cdr token) (cdr (supertag-index-source-token collections)))))

;;; --- Incremental Maintenance ---

(defun supertag-index--add-relation-entry (relation-id from-id to-id)
  "Add RELATION-ID to the indexes for FROM-ID and TO-ID."
  (let ((from-set (gethash from-id supertag--index-relations-by-from)))
    (unless from-set
      (setq from-set (make-hash-table :test 'equal))
      (puthash from-id from-set supertag--index-relations-by-from))
    (puthash relation-id t from-set))
  (let ((to-set (gethash to-id supertag--index-relations-by-to)))
    (unless to-set
      (setq to-set (make-hash-table :test 'equal))
      (puthash to-id to-set supertag--index-relations-by-to))
    (puthash relation-id t to-set)))

(defun supertag-index--remove-relation-entry (relation-id from-id to-id)
  "Remove RELATION-ID from the indexes for FROM-ID and TO-ID."
  (let ((from-set (gethash from-id supertag--index-relations-by-from)))
    (when from-set
      (remhash relation-id from-set)
      (when (= 0 (hash-table-count from-set))
        (remhash from-id supertag--index-relations-by-from))))
  (let ((to-set (gethash to-id supertag--index-relations-by-to)))
    (when to-set
      (remhash relation-id to-set)
      (when (= 0 (hash-table-count to-set))
        (remhash to-id supertag--index-relations-by-to)))))

(defun supertag-index--on-relation-changed
    (relation-id old-from old-to new-from new-to)
  "Apply one completed Store mutation of RELATION-ID to relation indexes."
  (let* ((current-token (supertag-index-source-token '(:relations)))
         (old-revision (alist-get :relations
                                  (cdr supertag--index-relations-source-token)))
         (current-revision (alist-get :relations (cdr current-token))))
    (when (and old-revision
               (eq (car supertag--index-relations-source-token) supertag--store)
               (= (1+ old-revision) current-revision))
      (when (and old-from old-to)
        (supertag-index--remove-relation-entry relation-id old-from old-to))
      (when (and new-from new-to)
        (supertag-index--add-relation-entry relation-id new-from new-to))
      (setq supertag--index-relations-source-token current-token))))

;;; --- Full Rebuild ---

(defun supertag-index-rebuild-relations ()
  "Rebuild relation indexes from the :relations collection.
Call this after loading the store from disk."
  (setq supertag--index-relations-by-from (make-hash-table :test 'equal))
  (setq supertag--index-relations-by-to   (make-hash-table :test 'equal))
  (when (and (boundp 'supertag--store)
             (hash-table-p supertag--store))
    (let ((relations (gethash :relations supertag--store)))
      (when (hash-table-p relations)
        (maphash
         (lambda (rel-id relation)
           (when relation
             (let ((from-id (plist-get relation :from))
                   (to-id   (plist-get relation :to)))
               (when (and from-id to-id)
                 (supertag-index--add-relation-entry rel-id from-id to-id)))))
         relations))))
  (setq supertag--index-relations-source-token
        (supertag-index-source-token '(:relations))))

(defun supertag-index--ensure-relations ()
  "Cold rebuild relation indexes when their Store source changed."
  (unless (supertag-index-source-current-p
           supertag--index-relations-source-token '(:relations))
    (supertag-index-rebuild-relations)))

(defun supertag-node-tag-query-keys (node-data)
  "Return Semantic Tag IDs and Org Tag Occurrences from NODE-DATA."
  (delete-dups
   (append (copy-sequence (or (plist-get node-data :tags) '()))
           (copy-sequence (or (plist-get node-data :tag-occurrences) '())))))

(defun supertag-index-clear-nodes-by-tag ()
  "Clear the node membership index."
  (setq supertag--index-nodes-by-tag (make-hash-table :test 'equal)
        supertag--index-node-ranks (make-hash-table :test 'equal)
        supertag--index-nodes-source-token nil))

(defun supertag-index-rebuild-nodes-by-tag ()
  "Rebuild Tag/occurrence -> node membership from Document Projections."
  (supertag-index-clear-nodes-by-tag)
  (let ((nodes (and (boundp 'supertag--store)
                    (hash-table-p supertag--store)
                    (gethash :nodes supertag--store)))
        (rank 0))
    (when (hash-table-p nodes)
      (maphash
       (lambda (node-id node)
         (puthash node-id rank supertag--index-node-ranks)
         (setq rank (1+ rank))
         (dolist (tag (supertag-node-tag-query-keys node))
           (when (stringp tag)
             (let ((set (or (gethash tag supertag--index-nodes-by-tag)
                            (let ((new (make-hash-table :test 'equal)))
                              (puthash tag new supertag--index-nodes-by-tag)
                              new))))
               (puthash node-id t set)))))
       nodes)))
  (setq supertag--index-nodes-source-token
        (supertag-index-source-token '(:nodes))))

(defun supertag-index--ensure-nodes-by-tag ()
  "Cold rebuild node membership when its Document Projection changed."
  (unless (supertag-index-source-current-p
           supertag--index-nodes-source-token '(:nodes))
    (supertag-index-rebuild-nodes-by-tag)))

(defun supertag-index-find-node-ids-by-tags (tag-ids)
  "Return node IDs belonging to any ID/token in TAG-IDS."
  (supertag-index--ensure-nodes-by-tag)
  (let ((seen (make-hash-table :test 'equal))
        result)
    (dolist (tag-id tag-ids)
      (when-let* ((set (gethash tag-id supertag--index-nodes-by-tag)))
        (maphash (lambda (node-id _present)
                   (puthash node-id t seen))
                 set)))
    (maphash (lambda (node-id _present) (push node-id result)) seen)
    (sort result
          (lambda (left right)
            (< (gethash left supertag--index-node-ranks most-positive-fixnum)
               (gethash right supertag--index-node-ranks most-positive-fixnum))))))

(defun supertag-index-clear-all ()
  "Clear every Store-derived runtime index without touching the Store."
  (interactive)
  (setq supertag--index-relations-by-from (make-hash-table :test 'equal)
        supertag--index-relations-by-to (make-hash-table :test 'equal)
        supertag--index-relations-source-token nil)
  (supertag-index-clear-nodes-by-tag)
  (when (fboundp 'supertag-tag-index-clear)
    (supertag-tag-index-clear))
  (when (fboundp 'supertag-schema-clear-global-field-caches)
    (supertag-schema-clear-global-field-caches))
  (when (fboundp 'supertag-ops-schema-clear-cache)
    (supertag-ops-schema-clear-cache))
  (when (fboundp 'supertag-automation-clear-rule-index)
    (supertag-automation-clear-rule-index)))

(defun supertag-index-rebuild-all ()
  "Cold rebuild every Store-derived runtime index as one generation."
  (interactive)
  (supertag-index-clear-all)
  (condition-case err
      (progn
        (supertag-index-rebuild-relations)
        (when (fboundp 'supertag-tag-index-rebuild)
          (supertag-tag-index-rebuild))
        (supertag-index-rebuild-nodes-by-tag)
        (when (fboundp 'supertag-schema-rebuild-global-field-caches)
          (supertag-schema-rebuild-global-field-caches))
        (when (fboundp 'supertag-ops-schema-rebuild-cache)
          (supertag-ops-schema-rebuild-cache))
        (when (fboundp 'supertag-rebuild-rule-index)
          (supertag-rebuild-rule-index))
        (when (called-interactively-p 'interactive)
          (message "Supertag derived indexes rebuilt."))
        t)
    (error
     (supertag-index-clear-all)
     (signal (car err) (cdr err)))))

;;; --- Index-Accelerated Queries ---

(defun supertag-index--collect-relations (entity-id index-table &optional type)
  "Collect relation plists for ENTITY-ID from INDEX-TABLE, optionally filtered by TYPE."
  (let ((id-set (gethash entity-id index-table))
        (result '()))
    (when id-set
      (let ((relations-ht (and (boundp 'supertag--store)
                               (hash-table-p supertag--store)
                               (gethash :relations supertag--store))))
        (when (hash-table-p relations-ht)
          (maphash
           (lambda (rel-id _v)
             (let ((relation (gethash rel-id relations-ht)))
               (when (and relation
                          (or (null type)
                              (eq (plist-get relation :type) type)))
                 (push relation result))))
           id-set))))
    result))

(defun supertag-index-find-by-from (from-id &optional type)
  "Find relations originating from FROM-ID.  O(k) where k = matching relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (supertag-index--collect-relations from-id supertag--index-relations-by-from type))

(defun supertag-index-find-by-to (to-id &optional type)
  "Find relations targeting TO-ID.  O(k) where k = matching relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (supertag-index--collect-relations to-id supertag--index-relations-by-to type))

(defun supertag-index-find-between (from-id to-id &optional type)
  "Find relations from FROM-ID to TO-ID.  O(k) where k = from-id's relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (let ((id-set (gethash from-id supertag--index-relations-by-from))
        (result '()))
    (when id-set
      (let ((relations-ht (and (boundp 'supertag--store)
                               (hash-table-p supertag--store)
                               (gethash :relations supertag--store))))
        (when (hash-table-p relations-ht)
          (maphash
           (lambda (rel-id _v)
             (let ((relation (gethash rel-id relations-ht)))
               (when (and relation
                          (equal (plist-get relation :to) to-id)
                          (or (null type)
                              (eq (plist-get relation :type) type)))
                 (push relation result))))
           id-set))))
    result))

(add-hook 'supertag-after-transaction-rollback-hook
          #'supertag-index-rebuild-all)

(provide 'supertag-core-index)

;;; supertag-core-index.el ends here
